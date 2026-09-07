import Adapters
import Foundation
import TerminalCore
import Testing

@Suite("§7.1 実 git と実ファイルシステムでの状態重ね合わせ")
struct WorktreeGitStateReaderIntegrationTests {
  /// macOS の git は `core.precomposeunicode` が既定 true で、ディスク上が NFD でも出力は NFC。
  /// 列挙側は FS のバイト列をそのまま返すため、両者を突き合わせられることを実物で固定する。
  @Test("NFD の名前でもディレクトリと配下ファイルの状態が食い違わない", .timeLimit(.minutes(1)))
  func matchesDecomposedNamesAgainstGitOutput() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      let decomposedName = "e\u{0301}dir"
      try FileManager.default.createDirectory(
        at: root.appending(path: decomposedName), withIntermediateDirectories: false)
      try Data("y\n".utf8).write(to: root.appending(path: decomposedName + "/f.txt"))

      let overlay = WorktreeFileGitStateOverlay(entries: try await repository.stateEntries())
      let listedName = try #require(
        FileBrowserDirectoryReader(worktreeRoot: root).children(in: nil)
          .first { $0.name.contains("dir") }?.name)
      let directory = try #require(WorktreeRelativePath(listedName))
      let file = try #require(WorktreeRelativePath(listedName + "/f.txt"))

      #expect(Array(listedName.utf8) != Array("\u{00E9}dir".utf8))
      #expect(overlay.state(for: directory, kind: .directory) == .untracked)
      #expect(overlay.state(for: file, kind: .file) == .untracked)
    }
  }

  @Test("変更の無いサブモジュールでも配下を「変更なし」と主張しない", .timeLimit(.minutes(1)))
  func doesNotClaimCleanStateInsideSubmodule() async throws {
    try await withGitRepository { repository in
      let child = repository.root.appending(path: "child")
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      try await repository.git(["init", "-q", "-b", "main"], in: "child")
      try Data("s\n".utf8).write(to: child.appending(path: "s.txt"))
      try await repository.git(["add", "."], in: "child")
      try await repository.git(["commit", "-q", "-m", "child"], in: "child")
      try await repository.git([
        "-c", "protocol.file.allow=always", "submodule", "--quiet", "add", child.path, "sub",
      ])
      try await repository.git(["commit", "-q", "-m", "add submodule"])

      let overlay = WorktreeFileGitStateOverlay(entries: try await repository.stateEntries())

      let submodule = try #require(WorktreeRelativePath("sub"))
      #expect(overlay.state(for: submodule, kind: .directory) == nil)
      #expect(
        overlay.state(for: try #require(WorktreeRelativePath("sub/s.txt")), kind: .file) == nil)
      #expect(
        overlay.state(for: try #require(WorktreeRelativePath("p.txt")), kind: .file)
          == .tracked(.unchanged))
    }
  }

  @Test("worktree root の .git を列挙しない", .timeLimit(.minutes(1)))
  func hidesGitDirectory() async throws {
    try await withGitRepository { repository in
      try Data("p\n".utf8).write(to: repository.mainWorktree.appending(path: "p.txt"))

      let children = try FileBrowserDirectoryReader(worktreeRoot: repository.mainWorktree)
        .children(in: nil)

      #expect(children.map(\.name) == ["p.txt"])
    }
  }
}

extension GitTestRepository {
  fileprivate func stateEntries() async throws -> [WorktreeGitStateEntry] {
    try Data("p\n".utf8).write(to: mainWorktree.appending(path: "p.txt"))
    try await git(["add", "p.txt"])
    try await git(["commit", "-q", "-m", "p"])
    let reader = try WorktreeGitStateReader(
      repositoryDirectory: mainWorktree,
      processRunner: FoundationProcessRunner())
    return try await reader.read().entries
  }
}
