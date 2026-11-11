import Foundation
import TerminalCore
import Testing

@testable import Adapters

// reflog の記録と symbolic ref の解決は git の版で変わりうるため、判定前に前提を確かめる
// (git 2.54.0 で計測、CI の 2.56.0 は未計測)。
@Suite("§9.1.1 実 git での symbolic ref の分岐元")
struct DiffForkPointSymbolicRefIntegrationTests {
  @Test("symbolic ref の別名から作った branch では分岐元を使わない", .timeLimit(.minutes(1)))
  func ignoresSymbolicRefAliasStartPoint() async throws {
    try await withGitRepository { repository in
      try await repository.git(["symbolic-ref", "refs/heads/alias", "refs/heads/main"])
      try await repository.switchToForkedBranch(from: "alias", resolvingTo: "refs/heads/main")
      let refs = try await repository.refNameLines()
      try #require(refs.contains(Array("refs/heads/alias".utf8)))

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  // origin/HEAD を分岐元から弾くのは解決先との照合ではなく、`GitBranchRef` が /HEAD を
  // 除くため候補が一覧に入らないことである。同じ branch に着くので source まで検証する。
  @Test(
    "origin/HEAD から作った branch では分岐元を使わず origin/HEAD へ進む",
    .timeLimit(.minutes(1)))
  func fallsBackToOriginHeadForOriginHeadStartPoint() async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
      try await repository.git([
        "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main",
      ])
      try await repository.git(["switch", "-q", "-c", "x", "origin/HEAD"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from origin/HEAD", of: "refs/heads/x")
      let resolved = try await repository.gitExitCode([
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", "origin/HEAD",
      ])
      try #require(resolved.exitCode == 0)
      try #require(resolved.stdout == "refs/remotes/origin/main\n")
      let refs = try await repository.refNameLines()
      try #require(refs.contains(Array("refs/remotes/origin/HEAD".utf8)))

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .remote("origin/main"), source: .originHead))
    }
  }
}
