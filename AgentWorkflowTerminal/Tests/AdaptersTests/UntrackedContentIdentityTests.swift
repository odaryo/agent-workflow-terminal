import Darwin
import Foundation
import Testing

@testable import Adapters

@Suite("§9.3 読めなかった untracked の内容識別子")
struct UntrackedContentIdentityTests {
  @Test("ハッシュ上限以下の binary は同サイズの書き換えで変わる")
  func detectsSameSizeBinaryRewrite() throws {
    try withIdentityDirectory { root in
      let file = root.appending(path: "binary")
      try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: file)
      let identity = UntrackedContentIdentity(maximumHashedByteCount: 8)
      let before = identity.identity(worktreeRoot: root, path: "binary")
      try Data([0, 7, 6, 5, 4, 3, 2, 1]).write(to: file)
      #expect(identity.identity(worktreeRoot: root, path: "binary") != before)
    }
  }

  @Test("ハッシュ上限以下は反復・touch・同内容の書き直しで変わらない")
  func keepsHashedContentStable() throws {
    try withIdentityDirectory { root in
      let file = root.appending(path: "binary")
      let bytes = Data([0, 1, 2, 3, 4, 5, 6, 7])
      try bytes.write(to: file)
      let identity = UntrackedContentIdentity(maximumHashedByteCount: 8)
      let before = identity.identity(worktreeRoot: root, path: "binary")
      #expect(identity.identity(worktreeRoot: root, path: "binary") == before)
      try changeIdentityModificationDate(of: file)
      #expect(identity.identity(worktreeRoot: root, path: "binary") == before)
      try bytes.write(to: file)
      #expect(identity.identity(worktreeRoot: root, path: "binary") == before)
    }
  }

  @Test("ハッシュ上限超過は同サイズの書き換えで変わる")
  func detectsOversizedRewrite() throws {
    try withIdentityDirectory { root in
      let file = root.appending(path: "large")
      try Data(repeating: 1, count: 9).write(to: file)
      let identity = UntrackedContentIdentity(maximumHashedByteCount: 8)
      let before = identity.identity(worktreeRoot: root, path: "large")
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      let modificationDate = try #require(attributes[.modificationDate] as? Date)
      try Data(repeating: 2, count: 9).write(to: file)
      try FileManager.default.setAttributes(
        [.modificationDate: modificationDate], ofItemAtPath: file.path)
      #expect(identity.identity(worktreeRoot: root, path: "large") != before)
    }
  }

  @Test("ハッシュ上限超過は反復では変わらず mtime だけの変更でも変わる")
  func detectsOversizedTouch() throws {
    try withIdentityDirectory { root in
      let file = root.appending(path: "large")
      try Data(repeating: 1, count: 9).write(to: file)
      let identity = UntrackedContentIdentity(maximumHashedByteCount: 8)
      let before = identity.identity(worktreeRoot: root, path: "large")
      #expect(identity.identity(worktreeRoot: root, path: "large") == before)
      try changeIdentityModificationDate(of: file)
      #expect(identity.identity(worktreeRoot: root, path: "large") != before)
    }
  }

  @Test("symlink の付け替えで変わる")
  func detectsSymlinkRetargeting() throws {
    try withIdentityDirectory { root in
      try Data([1]).write(to: root.appending(path: "first"))
      try Data([2]).write(to: root.appending(path: "second"))
      let link = root.appending(path: "link")
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "first")
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "link")
      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "second")
      #expect(identity.identity(worktreeRoot: root, path: "link") != before)
    }
  }

  @Test("symlink のリンク先の内容変更は検知しない")
  func ignoresSymlinkTargetContents() throws {
    try withIdentityDirectory { root in
      let target = root.appending(path: "target")
      try Data([1]).write(to: target)
      try FileManager.default.createSymbolicLink(
        atPath: root.appending(path: "link").path, withDestinationPath: "target")
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "link")
      try Data([2]).write(to: target)
      #expect(identity.identity(worktreeRoot: root, path: "link") == before)
    }
  }

  @Test("畳まれたディレクトリは反復では変わらず直下の追加で変わる")
  func detectsDirectoryAddition() throws {
    try withIdentityDirectory { root in
      let nested = root.appending(path: "nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "nested/")
      #expect(identity.identity(worktreeRoot: root, path: "nested/") == before)
      try Data([1]).write(to: nested.appending(path: "added"))
      #expect(identity.identity(worktreeRoot: root, path: "nested/") != before)
    }
  }

  @Test("畳まれたディレクトリの深い階層の同サイズ書き換えで変わる")
  func detectsDeepRewrite() throws {
    try withIdentityDirectory { root in
      let deep = root.appending(path: "nested/deep/deeper")
      try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
      let file = deep.appending(path: "file")
      try Data([1, 2]).write(to: file)
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "nested/")
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      let modificationDate = try #require(attributes[.modificationDate] as? Date)
      try Data([3, 4]).write(to: file)
      try FileManager.default.setAttributes(
        [.modificationDate: modificationDate], ofItemAtPath: file.path)
      #expect(identity.identity(worktreeRoot: root, path: "nested/") != before)
    }
  }

  @Test("畳まれたディレクトリの中の削除で変わる")
  func detectsDirectoryDeletion() throws {
    try withIdentityDirectory { root in
      let nested = root.appending(path: "nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let file = nested.appending(path: "file")
      try Data([1]).write(to: file)
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "nested/")
      try FileManager.default.removeItem(at: file)
      #expect(identity.identity(worktreeRoot: root, path: "nested/") != before)
    }
  }

  @Test("畳まれたディレクトリ内の touch でも変わる")
  func detectsDirectoryFileTouch() throws {
    try withIdentityDirectory { root in
      let nested = root.appending(path: "nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let file = nested.appending(path: "file")
      try Data([1]).write(to: file)
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "nested/")
      try changeIdentityModificationDate(of: file)
      #expect(identity.identity(worktreeRoot: root, path: "nested/") != before)
    }
  }

  @Test("どの階層でも .git はファイル・ディレクトリとも識別子に含めない", arguments: ["", "deep/"])
  func ignoresGitEntries(_ prefix: String) throws {
    try withIdentityDirectory { root in
      let directory = root.appending(path: "nested/\(prefix)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let git = directory.appending(path: ".git")
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "nested/")
      try Data([1]).write(to: git)
      #expect(identity.identity(worktreeRoot: root, path: "nested/") == before)
      try Data([2, 3]).write(to: git)
      #expect(identity.identity(worktreeRoot: root, path: "nested/") == before)
      try FileManager.default.removeItem(at: git)
      try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
      try Data([4]).write(to: git.appending(path: "config"))
      #expect(identity.identity(worktreeRoot: root, path: "nested/") == before)
      try Data([5, 6]).write(to: git.appending(path: "config"))
      #expect(identity.identity(worktreeRoot: root, path: "nested/") == before)
    }
  }

  @Test("名前順の項目上限より後ろの変更は検知しないが上限内は検知する")
  func boundsDirectoryEntriesInNameOrder() throws {
    try withIdentityDirectory { root in
      let nested = root.appending(path: "nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      for name in ["z", "c", "b", "a"] {
        try Data([1]).write(to: nested.appending(path: name))
      }
      let identity = UntrackedContentIdentity(maximumEntryCount: 3)
      let before = identity.identity(worktreeRoot: root, path: "nested/")
      try Data([2, 3]).write(to: nested.appending(path: "z"))
      #expect(identity.identity(worktreeRoot: root, path: "nested/") == before)
      try Data([2, 3]).write(to: nested.appending(path: "a"))
      #expect(identity.identity(worktreeRoot: root, path: "nested/") != before)
    }
  }

  @Test("項目上限があっても深い階層より先に浅い階層の同サイズ書き換えを検知する")
  func detectsShallowRewriteBeforeDeeperEntries() throws {
    try withIdentityDirectory { root in
      let directory = root.appending(path: "nested/.a")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for name in ["x", "y", "z"] {
        try Data([1]).write(to: directory.appending(path: name))
      }
      let file = root.appending(path: "nested/b")
      try Data([1]).write(to: file)
      let identity = UntrackedContentIdentity(maximumEntryCount: 3)
      let before = identity.identity(worktreeRoot: root, path: "nested/")
      try Data([2]).write(to: file)
      #expect(identity.identity(worktreeRoot: root, path: "nested/") != before)
    }
  }

  @Test("FIFO はハングせず反復しても変わらない", .timeLimit(.minutes(1)))
  func observesFIFOWithoutBlocking() async throws {
    let root = try makeIdentityDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appending(path: "pipe")
    try #require(mkfifo(fifo.path, 0o644) == 0)
    let first = try #require(await fifoIdentity(worktreeRoot: root))
    let second = try #require(await fifoIdentity(worktreeRoot: root))
    #expect(first == second)
  }

  @Test("消えたパスでも落ちず存在したときとは変わる")
  func detectsDisappearance() throws {
    try withIdentityDirectory { root in
      let file = root.appending(path: "file")
      try Data([1]).write(to: file)
      let identity = UntrackedContentIdentity()
      let before = identity.identity(worktreeRoot: root, path: "file")
      try FileManager.default.removeItem(at: file)
      let missing = identity.identity(worktreeRoot: root, path: "file")
      #expect(missing != before)
      #expect(identity.identity(worktreeRoot: root, path: "file") == missing)
    }
  }
}

private func makeIdentityDirectory() throws -> URL {
  let root = URL(fileURLWithPath: "/private/tmp/awt-identity-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  return root
}

private func withIdentityDirectory(_ body: (URL) throws -> Void) throws {
  let root = try makeIdentityDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

private func changeIdentityModificationDate(of file: URL) throws {
  let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
  let date = try #require(attributes[.modificationDate] as? Date)
  try FileManager.default.setAttributes(
    [.modificationDate: date.addingTimeInterval(60)], ofItemAtPath: file.path)
}

// 同期 I/O が FIFO を開いて止まると Task のキャンセルも効かないため、別スレッドと期限で検証する。
private func fifoIdentity(worktreeRoot: URL) async -> String? {
  let identities = AsyncStream<String> { continuation in
    Thread.detachNewThread {
      continuation.yield(
        UntrackedContentIdentity().identity(worktreeRoot: worktreeRoot, path: "pipe"))
      continuation.finish()
    }
  }
  return await withTaskGroup(of: String?.self) { group in
    group.addTask {
      for await identity in identities { return identity }
      return nil
    }
    group.addTask {
      try? await ContinuousClock().sleep(for: .seconds(5))
      return nil
    }
    let first = await group.next()
    group.cancelAll()
    guard let first else { return nil }
    return first
  }
}
