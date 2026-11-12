import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§9.3 実 git での untracked 内容変更検知")
struct DiffSnapshotUntrackedIdentityTests {
  @Test("畳まれた untracked ディレクトリへの3ファイル追加を検知する", .timeLimit(.minutes(1)))
  func detectsChangesInsideFoldedUntrackedDirectory() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      let nested = try await makeNestedRepository(in: repository)
      try Data("existing\n".utf8).write(to: nested.appending(path: "existing.txt"))
      let opened = try await openUntrackedSnapshot(at: root)
      let file = try #require(opened.file(origin: .untracked, path: "nested/"))
      try #require(file.content == .unreadable(.notReadable))

      for name in ["a.txt", "b.txt", "c.txt"] {
        try Data("added\n".utf8).write(to: nested.appending(path: name))
      }
      let comparison = try await compareUntrackedSnapshot(opened, at: root)
      #expect(comparison.fileChanges == [.modified(origin: .untracked, path: "nested/")])
    }
  }

  @Test("untracked の symlink の付け替えを検知する", .timeLimit(.minutes(1)))
  func detectsSymlinkRetargeting() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try Data("first\n".utf8).write(to: root.appending(path: "first.txt"))
      try Data("second\n".utf8).write(to: root.appending(path: "second.txt"))
      let link = root.appending(path: "link")
      try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: "first.txt")
      let opened = try await openUntrackedSnapshot(at: root)
      let file = try #require(opened.file(origin: .untracked, path: "link"))
      try #require(file.content == .unreadable(.notReadable))

      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: "second.txt")
      let comparison = try await compareUntrackedSnapshot(opened, at: root)
      #expect(comparison.fileChanges == [.modified(origin: .untracked, path: "link")])
    }
  }

  @Test("同サイズの untracked binary の書き換えを検知する", .timeLimit(.minutes(1)))
  func detectsSameSizeBinaryRewrite() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      let binary = root.appending(path: "binary")
      try Data([0, 1, 2, 3]).write(to: binary)
      let opened = try await openUntrackedSnapshot(at: root)
      let file = try #require(opened.file(origin: .untracked, path: "binary"))
      try #require(file.content == .unreadable(.binary(byteCount: 4)))

      try Data([0, 3, 2, 1]).write(to: binary)
      let comparison = try await compareUntrackedSnapshot(opened, at: root)
      #expect(comparison.fileChanges == [.modified(origin: .untracked, path: "binary")])
    }
  }

  @Test("入れ子 repo・symlink・binary・テキストは無変更なら2回とも変更なし", .timeLimit(.minutes(1)))
  func keepsUnchangedObservationsStable() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      let nested = try await makeNestedRepository(in: repository)
      try Data("nested\n".utf8).write(to: nested.appending(path: "file.txt"))
      try Data("plain\n".utf8).write(to: root.appending(path: "plain.txt"))
      try Data([0, 1, 2, 3]).write(to: root.appending(path: "binary"))
      try FileManager.default.createSymbolicLink(
        atPath: root.appending(path: "link").path, withDestinationPath: "plain.txt")
      let opened = try await openUntrackedSnapshot(at: root)
      try #require(
        opened.section(.untracked)?.files.map(\.path).sorted()
          == ["binary", "link", "nested/", "plain.txt"])
      try #require(
        opened.file(origin: .untracked, path: "nested/")?.content == .unreadable(.notReadable))
      try #require(
        opened.file(origin: .untracked, path: "link")?.content == .unreadable(.notReadable))
      try #require(
        opened.file(origin: .untracked, path: "binary")?.content
          == .unreadable(.binary(byteCount: 4)))

      let first = try await compareUntrackedSnapshot(opened, at: root)
      let second = try await compareUntrackedSnapshot(opened, at: root)
      #expect(first.fileChanges.isEmpty)
      #expect(second.fileChanges.isEmpty)
    }
  }

  @Test("読めている untracked テキストの変更を検知する", .timeLimit(.minutes(1)))
  func detectsReadableUntrackedChanges() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      let plain = root.appending(path: "plain.txt")
      try Data("plain\n".utf8).write(to: plain)
      let opened = try await openUntrackedSnapshot(at: root)
      let file = try #require(opened.file(origin: .untracked, path: "plain.txt"))
      try #require(file.hunks.flatMap(\.lines).map(\.text) == ["plain"])

      try Data("plain changed\n".utf8).write(to: plain)
      let comparison = try await compareUntrackedSnapshot(opened, at: root)
      #expect(comparison.fileChanges == [.modified(origin: .untracked, path: "plain.txt")])
    }
  }
}

private func makeNestedRepository(in repository: GitTestRepository) async throws -> URL {
  let nested = repository.mainWorktree.appending(path: "nested")
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
  try await repository.git(["init", "-q", "-b", "main", nested.path])
  return nested
}

private func openUntrackedSnapshot(at root: URL) async throws -> DiffSnapshot {
  let builder = try DiffSnapshotBuilder(
    worktreeRoot: root, processRunner: FoundationProcessRunner())
  let result = try await builder.build(
    .base(branch: .local("main")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
  try #require(result.patchFailures.isEmpty)
  try #require(result.statusFailures.isEmpty)
  return result.snapshot
}

private func compareUntrackedSnapshot(
  _ opened: DiffSnapshot, at root: URL
) async throws -> DiffSnapshotComparison {
  let builder = try DiffSnapshotBuilder(
    worktreeRoot: root, processRunner: FoundationProcessRunner())
  let current = try await builder.observe(.base(branch: .local("main")))
  return DiffSnapshotChangeDetection.compare(opened: opened.observation, current: current)
}
