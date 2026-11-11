import CryptoKit
import Darwin
import Foundation
import TerminalCore

struct UntrackedContentIdentity: Sendable {
  static let defaultMaximumHashedByteCount = FileViewThresholds.defaultAbsoluteMaximumByteCount
  static let defaultMaximumEntryCount = 10_000

  private let maximumHashedByteCount: Int
  private let maximumEntryCount: Int

  init(
    maximumHashedByteCount: Int = Self.defaultMaximumHashedByteCount,
    maximumEntryCount: Int = Self.defaultMaximumEntryCount
  ) {
    self.maximumHashedByteCount = max(0, maximumHashedByteCount)
    self.maximumEntryCount = max(0, maximumEntryCount)
  }

  /// `path` は worktree 相対。末尾 `/` は畳まれたディレクトリ。
  func identity(worktreeRoot: URL, path: String) -> String {
    let url = worktreeRoot.appending(path: path)
    let absolutePath = Array(url.path.utf8)
    var identity = IdentityDigest()
    do {
      let info = try Self.fileInfo(at: absolutePath)
      identity.append("\(info.st_mode & S_IFMT)")
      switch info.st_mode & S_IFMT {
      case S_IFREG:
        identity.append(regularFileIdentity(at: url, info: info))
      case S_IFLNK:
        identity.append(try Self.linkTarget(at: absolutePath))
      case S_IFDIR where path.hasSuffix("/"):
        appendDirectory(at: absolutePath, to: &identity)
      default: break
      }
    } catch {
      identity.append(Self.failureIdentity(error))
    }
    return identity.finalize()
  }

  private func regularFileIdentity(at url: URL, info: stat) -> String {
    guard info.st_size <= maximumHashedByteCount else { return Self.metadata(info) }
    do {
      let opened = try FileContentReader.openRegularFile(at: url)
      defer { try? opened.handle.close() }
      guard opened.byteCount <= maximumHashedByteCount else { return Self.metadata(info) }
      var hash = SHA256()
      var remaining = maximumHashedByteCount
      while remaining > 0 {
        guard let chunk = try opened.handle.read(upToCount: min(1_048_576, remaining)),
          !chunk.isEmpty
        else { break }
        hash.update(data: chunk)
        remaining -= chunk.count
      }
      // 上限ちょうどの場合も余分な1バイトを読まず、増大は fd のサイズで確認する。
      var current = stat()
      guard fstat(opened.handle.fileDescriptor, &current) == 0 else {
        return Self.metadata(info)
      }
      guard current.st_size <= maximumHashedByteCount else { return Self.metadata(current) }
      return "sha256:\(Self.hex(hash.finalize()))"
    } catch {
      return Self.metadata(info)
    }
  }

  private func appendDirectory(at root: [UInt8], to identity: inout IdentityDigest) {
    var pending: [[UInt8]]
    do {
      pending = try Self.names(at: root)
    } catch {
      identity.append(Self.failureIdentity(error))
      return
    }
    var count = 0
    while count < maximumEntryCount, count < pending.count {
      let relativePath = pending[count]
      count += 1
      identity.append(relativePath)
      let absolutePath = root + [47] + relativePath
      do {
        let info = try Self.fileInfo(at: absolutePath)
        identity.append("\(info.st_mode & S_IFMT)")
        switch info.st_mode & S_IFMT {
        case S_IFREG:
          identity.append(Self.metadata(info))
        case S_IFLNK:
          identity.append(try Self.linkTarget(at: absolutePath))
        case S_IFDIR:
          // 上限の位置より後ろへ積んだ項目は訪れない。訪れた数で判定すると、幅優先では
          // 上限内のディレクトリをすべて readdir してしまう (3,000 × 300 件で 0.12 s → 0.75 s)。
          if pending.count < maximumEntryCount {
            let children = try Self.names(at: absolutePath)
            pending.append(contentsOf: children.map { relativePath + [47] + $0 })
          }
        default: break
        }
      } catch {
        identity.append(Self.failureIdentity(error))
      }
    }
    if count == maximumEntryCount { identity.append("entry-limit") }
  }

  private static func metadata(_ info: stat) -> String {
    "metadata:\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
      + ":\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
  }

  private struct FileSystemFailure: Error {
    let code: Int32
  }

  private static func failureIdentity(_ error: any Error) -> String {
    "error:\((error as? FileSystemFailure)?.code ?? EIO)"
  }

  private static func withPath<Value>(
    _ path: [UInt8], body: (UnsafePointer<CChar>) throws -> Value
  ) throws -> Value {
    try (path.map { CChar(bitPattern: $0) } + [0]).withUnsafeBufferPointer { buffer in
      guard let pointer = buffer.baseAddress else { throw FileSystemFailure(code: EINVAL) }
      return try body(pointer)
    }
  }

  private static func fileInfo(at path: [UInt8]) throws -> stat {
    try withPath(path) { pointer in
      var info = stat()
      guard lstat(pointer, &info) == 0 else { throw FileSystemFailure(code: errno) }
      return info
    }
  }

  private static func linkTarget(at path: [UInt8]) throws -> [UInt8] {
    try withPath(path) { pointer in
      var capacity = 256
      while true {
        var bytes = [UInt8](repeating: 0, count: capacity)
        let count = bytes.withUnsafeMutableBytes { buffer in
          readlink(pointer, buffer.bindMemory(to: CChar.self).baseAddress, buffer.count)
        }
        guard count >= 0 else { throw FileSystemFailure(code: errno) }
        if count < capacity { return Array(bytes.prefix(count)) }
        capacity *= 2
      }
    }
  }

  private static func names(at path: [UInt8]) throws -> [[UInt8]] {
    try withPath(path) { pointer in
      guard let directory = opendir(pointer) else { throw FileSystemFailure(code: errno) }
      defer { closedir(directory) }
      var names: [[UInt8]] = []
      while true {
        errno = 0
        guard let entry = readdir(directory) else {
          guard errno == 0 else { throw FileSystemFailure(code: errno) }
          return names.sorted { $0.lexicographicallyPrecedes($1) }
        }
        let name = withUnsafeBytes(of: entry.pointee.d_name) {
          Array($0.prefix(Int(entry.pointee.d_namlen)))
        }
        if name != [46], name != [46, 46], name != Array(".git".utf8) {
          names.append(name)
        }
      }
    }
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private struct IdentityDigest {
    private var hash = SHA256()

    mutating func append(_ value: String) {
      append(Array(value.utf8))
    }

    mutating func append(_ bytes: [UInt8]) {
      // パスやリンク先には区切り文字も入り得るため、長さを前置して曖昧な連結を避ける。
      hash.update(data: Data("\(bytes.count):".utf8))
      hash.update(data: Data(bytes))
    }

    func finalize() -> String {
      UntrackedContentIdentity.hex(hash.finalize())
    }
  }
}
