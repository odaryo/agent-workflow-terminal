import Darwin
import Foundation
import TerminalCore

public enum ProjectRegistryStoreError: Error, Sendable, Equatable {
  /// ファイルは在るが読めない。「保存が無い」(`load()` の `nil`) と混ぜてはならない。
  case readFailed(path: String, code: Int)
  case malformed(path: String, description: String)
  case unsupportedSchemaVersion(path: String, found: Int, supported: Int)
  case writeFailed(path: String, code: Int)
}

/// 登録済み Project の一覧を JSON ファイルとして保存する (Issue #372)。
///
/// 置き場と書き方は `WorktreeInventoryStore` に揃えた**暫定**実装で、同じく設計書 §22.1 の
/// SQLite + GRDB を採用するときに移行する。読み書きの規則 (壊れた symlink を「保存が無い」へ
/// 丸めない、一時ファイルからの `replaceItemAt`) の根拠は `WorktreeInventoryStore` の注釈を参照。
/// 共通化していないのは、既存の保存の挙動をこの変更で動かさないためである。
public actor ProjectRegistryStore {
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  /// - Returns: パスに何も無い (親ディレクトリごと無い場合を含む) ときだけ `nil`。
  ///   壊れたファイルを `nil` へ丸めると、次の保存で登録済みの一覧が黙って消える。
  public func load() throws(ProjectRegistryStoreError) -> PersistedProjectRegistry? {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
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
    guard schemaVersion == PersistedProjectRegistry.currentSchemaVersion else {
      throw .unsupportedSchemaVersion(
        path: fileURL.path,
        found: schemaVersion,
        supported: PersistedProjectRegistry.currentSchemaVersion
      )
    }

    do {
      return try JSONDecoder().decode(PersistedProjectRegistry.self, from: data)
    } catch {
      throw .malformed(path: fileURL.path, description: String(describing: error))
    }
  }

  public func save(_ registry: PersistedProjectRegistry) throws(ProjectRegistryStoreError) {
    let directory = fileURL.deletingLastPathComponent()
    let temporaryURL = directory.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(registry).write(to: temporaryURL)
      _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw .writeFailed(path: fileURL.path, code: (error as NSError).code)
    }
  }

  /// `applicationSupportDirectory` を引数で受けるのは `WorktreeInventoryStore.defaultFileURL` と
  /// 同じく、テストが実ユーザーの Application Support を読み書きしないようにするため。
  public static func defaultFileURL(applicationSupportDirectory: URL) -> URL {
    applicationSupportDirectory
      .appendingPathComponent(
        WorktreeInventoryStore.applicationDirectoryName, isDirectory: true
      )
      .appendingPathComponent("project-registry.json", isDirectory: false)
  }

  private func isAbsent(path: String) -> Bool {
    var status = stat()
    guard lstat(path, &status) != 0 else { return false }
    return errno == ENOENT
  }

  private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int
  }
}
