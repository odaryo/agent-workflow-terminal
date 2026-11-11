import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// §9.1.1 の分岐元を実 git で固定する。reflog の記録と `rev-parse` の解決は git の版で変わりうる
/// ので、前提にした記録は `#require` で確かめてから判定する (計測は git 2.54.0、CI は 2.56.0)。
@Suite("§9.1.1 実 git での分岐元")
struct DiffForkPointIntegrationTests {
  // 記録は生のまま残り (`@{-1}` / `@`)、解決は今の文脈で行われる。`@{-1}` は今の直前の branch、
  // `@` は自分自身になるので、どちらを比較元にしても分岐元ではない。
  @Test(
    "`@{-1}` と `@` から作った branch では分岐元を使わない", .timeLimit(.minutes(1)),
    arguments: [("@{-1}", "refs/heads/main"), ("@", "refs/heads/feature")])
  func ignoresContextualStartPoint(startPoint: String, resolvedNow: String) async throws {
    try await withGitRepository { repository in
      try await repository.git(["branch", "other"])
      try await repository.git(["checkout", "-q", "other"])
      try await repository.git(["checkout", "-q", "main"])
      try await repository.git(["branch", "feature", startPoint])
      try await repository.git(["checkout", "-q", "feature"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from " + startPoint, of: "refs/heads/feature")
      let resolved = try await repository.gitExitCode([
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", startPoint,
      ])
      try #require(resolved.exitCode == 0)
      try #require(resolved.stdout == resolvedNow + "\n")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test(
    "reflog が失効した branch では分岐元を使わない", .timeLimit(.minutes(1)),
    arguments: [
      ["reflog", "expire", "--expire=now", "refs/heads/feature"],
      // 作成の項目だけを消す。残る最古の項目は `commit: c1` になる。
      ["reflog", "delete", "refs/heads/feature@{1}"],
    ])
  func ignoresExpiredReflog(expire: [String]) async throws {
    try await withGitRepository { repository in
      try await repository.git(["branch", "local-base"])
      try await repository.git(["checkout", "-q", "-b", "feature", "local-base"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "c1"])
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("local-base"), source: .forkPoint))

      try await repository.git(expire)
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test("reflog を残さずに作った branch では分岐元を使わない", .timeLimit(.minutes(1)))
  func ignoresBranchWithoutReflog() async throws {
    try await withGitRepository { repository in
      try await repository.git(["branch", "local-base"])
      try await repository.git([
        "-c", "core.logAllRefUpdates=false", "branch", "feature", "local-base",
      ])
      try await repository.git(["checkout", "-q", "feature"])
      let exists = try await repository.gitExitCode(["reflog", "exists", "refs/heads/feature"])
      try #require(exists.exitCode == 1)

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test("`git worktree add -b` で作った worktree の分岐元を使う", .timeLimit(.minutes(1)))
  func resolvesForkPointInLinkedWorktree() async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
      let worktree = repository.root.appending(path: "wt")
      try await repository.git(["worktree", "add", "-q", "-b", "wt", worktree.path, "origin/main"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from origin/main", of: "refs/heads/wt")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: worktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .remote("origin/main"), source: .forkPoint))
    }
  }
}

extension GitTestRepository {
  func requireUpstream(_ fullName: String) async throws {
    let result = try await gitExitCode([
      "rev-parse", "--verify", "--quiet", "--symbolic-full-name", "@{upstream}",
    ])
    try #require(result.exitCode == 0)
    try #require(result.stdout == fullName + "\n")
  }

  func requireOldestReflogSubject(_ subject: String, of fullName: String) async throws {
    let result = try await gitExitCode([
      "reflog", "show", "--no-show-signature", "--format=%gs", fullName, "--",
    ])
    try #require(result.exitCode == 0)
    try #require(result.stdout.split(separator: "\n").last.map(String.init) == subject)
  }
}
