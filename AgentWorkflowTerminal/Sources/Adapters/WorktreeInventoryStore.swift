import CryptoKit
import Darwin
import Foundation
import TerminalCore

public enum WorktreeInventoryStoreError: Error, Sendable, Equatable {
  /// ファイルは在るが読めない。「保存が無い」(`load()` の `nil`) と混ぜてはならない。
  case readFailed(path: String, code: Int)
  case malformed(path: String, description: String)
  case unsupportedSchemaVersion(path: String, found: Int, supported: Int)
  case writeFailed(path: String, code: Int)
  /// `code` は `errno`。他の case の `code` (NSError の code) と領域が違う — 削除は `unlink` /
  /// `rmdir` / `opendir` を直接呼ぶため。
  case removeFailed(path: String, code: Int)
}

/// 登録解除で消しきれなかったものを、App がユーザーへ伝えるための値 (Issue #406)。
public struct WorktreeInventoryRemoval: Sendable, Equatable {
  public struct KeptDirectory: Sendable, Equatable {
    public let path: String
    /// 名前順。ディレクトリの列挙順は安定しないため。
    public let entries: [String]

    public init(path: String, entries: [String]) {
      self.path = path
      self.entries = entries
    }
  }

  /// `nil` はディレクトリまで消えた (元から無かった場合を含む) こと。
  public let keptDirectory: KeptDirectory?

  public init(keptDirectory: KeptDirectory?) {
    self.keptDirectory = keptDirectory
  }
}

/// worktree の Active/Inactive を JSON ファイルとして保存する**暫定**実装 (Issue #136 の決定 1)。
///
/// 設計書 §22.1 の SQLite + GRDB は現在の推奨であって未採用で、Application Support 上の正式 path と
/// schema / migration は §25 Storage の未確定事項である。ここで schema 進化の仕組みは作らず、
/// 読めない `schemaVersion` は失敗として上位へ返す。GRDB 採用時にこのファイルからの移行を行う。
public actor WorktreeInventoryStore {
  /// `Application Support/<app>/` の `<app>` (設計書 §22.1)。
  public static let applicationDirectoryName = "AgentWorkflowTerminal"

  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  /// - Returns: パスに何も無い (親ディレクトリごと無い場合を含む) ときだけ `nil`。
  ///   壊れたファイルや未知の `schemaVersion` を `nil` へ丸めると「保存が無い」と区別できず、
  ///   ユーザーの Active 指定が黙って全部消える。
  public func load() throws(WorktreeInventoryStoreError) -> PersistedWorktreeInventory? {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // macOS 26.5 実測: 対象ファイルが無い場合も、その親ディレクトリが無い場合も、リンク先の
      // 無い symlink の場合も NSCocoaErrorDomain 260 (`fileReadNoSuchFile`) になる。
      // (存在しないファイルは `fileNoSuchFile` (4) では**ない**。)
      // 260 をそのまま `nil` にすると、壊れた symlink という「読めないもの」が「保存が無い」へ
      // 丸まる。パスそのものに何も無いことは、リンクを辿らない `lstat` で別に確かめる。
      guard isAbsent(path: fileURL.path) else {
        throw .readFailed(path: fileURL.path, code: (error as NSError).code)
      }
      return nil
    } catch {
      throw .readFailed(path: fileURL.path, code: (error as NSError).code)
    }

    let schemaVersion: Int
    do {
      schemaVersion = try JSONDecoder().decode(SchemaVersionProbe.self, from: data).schemaVersion
    } catch {
      throw .malformed(path: fileURL.path, description: String(describing: error))
    }
    guard schemaVersion == PersistedWorktreeInventory.currentSchemaVersion else {
      throw .unsupportedSchemaVersion(
        path: fileURL.path,
        found: schemaVersion,
        supported: PersistedWorktreeInventory.currentSchemaVersion
      )
    }

    do {
      return try JSONDecoder().decode(PersistedWorktreeInventory.self, from: data)
    } catch {
      throw .malformed(path: fileURL.path, description: String(describing: error))
    }
  }

  public func save(
    _ inventory: PersistedWorktreeInventory
  ) throws(WorktreeInventoryStoreError) {
    let directory = fileURL.deletingLastPathComponent()
    let temporaryURL = directory.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      // `withoutEscapingSlashes` が無いと、保存する値の大半を占めるパスが `\/repo\/.git` になる
      // (macOS 26.5 実測)。`sortedKeys` は、保存形式のキー順を Swift の宣言順から切り離すため。
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(inventory).write(to: temporaryURL)
      // 同一ディレクトリへ書いてから置換するのは、書きかけのファイルを保存先に見せないため。
      // macOS 26.5 実測: `replaceItemAt` は保存先が存在しない場合も成功し、どちらの場合も
      // 一時ファイルは残らない。
      _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw .writeFailed(path: fileURL.path, code: (error as NSError).code)
    }
  }

  /// 既に無いことは失敗にしない。親ディレクトリ (`projects/<project-id>/`) は、`save()` が残した
  /// 自分の一時ファイルを消したうえで、空のときだけ消す。他のファイル (`.DS_Store` 等) は
  /// このアプリ以外が置いたものかもしれないので消さず、残ったことを戻り値で返す — 黙って残すと
  /// ユーザーには「削除した」と見えるため。
  ///
  /// `FileManager.removeItem` を使わないのは、保存先がディレクトリにすり替わっていた場合に
  /// 中身ごと再帰的に消すため。`unlink` / `rmdir` が辿らないのはパスの**最後の要素だけ**で、
  /// 途中の要素 (`projects/<project-id>` 自体が symlink の場合など) は辿る。途中の要素は検査しない。
  public func remove() throws(WorktreeInventoryStoreError) -> WorktreeInventoryRemoval {
    try Self.unlinkIfPresent(fileURL.path)

    let directory = fileURL.deletingLastPathComponent().path
    // 列挙に失敗しても止めない。空なら下の `rmdir` が消し、空でなければそこで列挙し直して失敗を返す。
    // 一時ファイルの `unlink` の失敗は本体と同じく throw する — 残せば `rmdir` が `ENOTEMPTY` になり、
    // 自分のごみを「他人のファイル」として報告することになる。
    for name in (try? Self.entries(of: directory)) ?? [] where isOwnTemporaryFile(name) {
      try Self.unlinkIfPresent(directory + "/" + name)
    }

    guard rmdir(directory) != 0 else { return WorktreeInventoryRemoval(keptDirectory: nil) }
    let code = errno
    if code == ENOENT { return WorktreeInventoryRemoval(keptDirectory: nil) }
    // 空でないディレクトリへの `rmdir` は POSIX 上 `ENOTEMPTY` と `EEXIST` のどちらも許される。
    guard code == ENOTEMPTY || code == EEXIST else {
      throw .removeFailed(path: directory, code: Int(code))
    }
    return WorktreeInventoryRemoval(
      keptDirectory: .init(path: directory, entries: try Self.entries(of: directory).sorted()))
  }

  /// `ENOENT` を成功にするのは、別の store が先に消していても「無い」という結果は同じだから。
  private static func unlinkIfPresent(_ path: String) throws(WorktreeInventoryStoreError) {
    guard unlink(path) != 0 else { return }
    let code = errno
    guard code == ENOENT else { throw .removeFailed(path: path, code: Int(code)) }
  }

  /// `save()` の一時ファイル名 (`.<保存先の名前>.<UUID>.tmp`) と同じ形のものだけを自分のものとみなす。
  private func isOwnTemporaryFile(_ name: String) -> Bool {
    let prefix = ".\(fileURL.lastPathComponent)."
    let suffix = ".tmp"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix),
      name.count > prefix.count + suffix.count
    else { return false }
    return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
  }

  /// `FileManager.contentsOfDirectory` を使わないのは、失敗が NSError の code で返り、
  /// `removeFailed` の `code` を `errno` に揃えられないため。
  private static func entries(of directory: String) throws(WorktreeInventoryStoreError) -> [String]
  {
    guard let stream = opendir(directory) else {
      throw .removeFailed(path: directory, code: Int(errno))
    }
    defer { closedir(stream) }

    var names: [String] = []
    while true {
      // `readdir` は終端でも失敗でも `nil` を返すので、`errno` を先に 0 にして区別する。
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw .removeFailed(path: directory, code: Int(errno)) }
        return names
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
      }
      if name != "." && name != ".." { names.append(name) }
    }
  }

  /// `applicationSupportDirectory` (`~/Library/Application Support` に当たるディレクトリ) を
  /// 引数で受けるのは、この関数を環境に触れない純粋関数に保ち、テストが実ユーザーの
  /// Application Support を読み書きしないようにするため。
  /// - Note: `<project-id>` に安定 ID (絶対パス) をそのまま使えないため、その UTF-8 バイト列の
  ///   SHA-256 を hex で使う。可読な slug を足さない — `TmuxSessionName` の slug 規則は
  ///   `list-sessions` を人が読むための規則であって、パスの規則ではない。
  public static func defaultFileURL(
    applicationSupportDirectory: URL,
    projectRootIdentity: WorktreeIdentity
  ) -> URL {
    applicationSupportDirectory
      .appendingPathComponent(applicationDirectoryName, isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(projectDirectoryName(for: projectRootIdentity), isDirectory: true)
      .appendingPathComponent("worktree-inventory.json", isDirectory: false)
  }

  /// `FileManager.fileExists(atPath:)` を使わないのは、あれが symlink を辿るため。macOS 26.5 実測:
  /// リンク先の無い symlink に対して `fileExists` は `false`、`lstat` は `rc=0` (リンク自体は在る)。
  /// `ENOENT` 以外の失敗 (`ENOTDIR`、`EACCES` 等) は「何も無い」の証明にならないので `false` を返し、
  /// 呼び出し側で読み取り失敗として扱わせる。
  private func isAbsent(path: String) -> Bool {
    var status = stat()
    guard lstat(path, &status) != 0 else { return false }
    return errno == ENOENT
  }

  private static func projectDirectoryName(for identity: WorktreeIdentity) -> String {
    SHA256.hash(data: Data(identity.rawValue.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /// 本体を復号する前に版数だけを読むための入れ物。未知の版数を「復号に失敗した」ではなく
  /// 「読めない版数だった」として返し分けるため。
  private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int
  }
}
