import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// §9.1 の範囲表示が読む値を、snapshot を開いた時点で記録していることを実 git で固定する。
@Suite("§9.1 snapshot が記録する範囲")
struct DiffSnapshotRangeIntegrationTests {
  @Test("Base Diff は開いた時点の branch と HEAD を記録する", .timeLimit(.minutes(1)))
  func recordsHeadForBaseDiff() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try await repository.git(["checkout", "-q", "-b", "feature"])
      try write("f\n", to: root, "f.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "feature"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let head = try #require(try await builder.recentCommits(maxCount: 1).first)
      let snapshot = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      #expect(snapshot.head == DiffSnapshotHead(branch: "feature", object: head.hash))
    }
  }

  @Test("detached HEAD では branch を持たない", .timeLimit(.minutes(1)))
  func recordsDetachedHead() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try await repository.git(["checkout", "-q", "--detach"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let head = try #require(try await builder.recentCommits(maxCount: 1).first)
      let snapshot = try await builder.build(
        .branch(name: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      #expect(snapshot.head == DiffSnapshotHead(branch: nil, object: head.hash))
    }
  }

  /// Commit Diff の `observation.headObject` は選んだ commit であり、HEAD ではない。
  @Test("Commit Diff でも HEAD を記録し、選んだ commit を HEAD として扱わない", .timeLimit(.minutes(1)))
  func recordsHeadForCommitDiff() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      for name in ["a", "b"] {
        try write("\(name)\n", to: root, "\(name).txt")
        try await repository.git(["add", "-A"])
        try await repository.git(["commit", "-q", "-m", name])
      }

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let commits = try await builder.recentCommits(maxCount: 3)
      let head = try #require(commits.first)
      let older = try #require(commits.first { $0.subject == "a" })
      let snapshot = try await builder.build(
        .commit(hash: older.hash, parentHashes: older.parentHashes),
        id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      #expect(snapshot.head == DiffSnapshotHead(branch: "main", object: head.hash))
      #expect(snapshot.observation.headObject == older.hash)
    }
  }

  /// `git merge-base` は共通祖先が無いと出力なしの終了コード 1、ref が無いと 128 で終わる
  /// (git 2.50.1 で実測)。前者だけを「merge-base が無い」として区別する。
  @Test("共通祖先の無い branch は merge-base 無しとして失敗する", .timeLimit(.minutes(1)))
  func reportsMissingMergeBase() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try await repository.git(["checkout", "-q", "--orphan", "unrelated"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "orphan"])
      try await repository.git(["checkout", "-q", "main"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      await #expect(throws: DiffSnapshotBuilderError.noMergeBase(branch: "unrelated")) {
        try await builder.build(
          .branch(name: "unrelated"), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      }
      await #expect(throws: DiffSnapshotBuilderError.noMergeBase(branch: "unrelated")) {
        try await builder.build(
          .base(branch: "unrelated"), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      }
    }
  }

  @Test("存在しない ref は merge-base 無しへ丸めない", .timeLimit(.minutes(1)))
  func keepsUnknownRefAsGitFailure() async throws {
    try await withGitRepository { repository in
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      do {
        _ = try await builder.build(
          .branch(name: "no-such-branch"), id: DiffSnapshotID(rawValue: UUID()), now: Date())
        Issue.record("存在しない ref で snapshot が作られた")
      } catch let error as DiffSnapshotBuilderError {
        guard case .git(.commandFailed(let exitCode, _, _)) = error else {
          Issue.record("想定外のエラー: \(error)")
          return
        }
        #expect(exitCode == 128)
      }
    }
  }

  private func write(_ contents: String, to root: URL, _ name: String) throws {
    try Data(contents.utf8).write(to: root.appending(path: name))
  }
}
