import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§9.1.1 実 git での起点の付け替え")
struct DiffForkPointResetIntegrationTests {
  @Test(
    "branch を dev へ付け替える各コマンドで、作成時より付け替え先を優先する",
    .timeLimit(.minutes(1)),
    arguments: ["checkout", "switch", "branch", "worktree"])
  func resolvesResetStartPoint(command: String) async throws {
    try await withGitRepository { repository in
      try await repository.prepareResetBranches()
      var worktree = repository.mainWorktree
      switch command {
      case "checkout":
        try await repository.git(["checkout", "-q", "-B", "feature", "dev"])
      case "switch":
        try await repository.git(["switch", "-q", "-C", "feature", "dev"])
      case "branch":
        try await repository.git(["checkout", "-q", "main"])
        try await repository.git(["branch", "-f", "feature", "dev"])
        try await repository.git(["checkout", "-q", "feature"])
      default:
        try await repository.git(["checkout", "-q", "main"])
        worktree = repository.root.appending(path: "linked")
        try await repository.git([
          "worktree", "add", "-q", "-B", "feature", worktree.path, "dev",
        ])
      }
      try await repository.requireReflogSubjects(
        ["branch: Reset to dev", "branch: Created from main"], of: "refs/heads/feature")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: worktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("dev"), source: .forkPoint))
    }
  }

  @Test("2回付け替えたら新しい other を採る", .timeLimit(.minutes(1)))
  func resolvesNewestResetStartPoint() async throws {
    try await withGitRepository { repository in
      try await repository.prepareResetBranches()
      try await repository.git(["checkout", "-q", "-B", "feature", "dev"])
      try await repository.git(["checkout", "-q", "-B", "feature", "other"])
      try await repository.requireReflogSubjects(
        ["branch: Reset to other", "branch: Reset to dev", "branch: Created from main"],
        of: "refs/heads/feature")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("other"), source: .forkPoint))
    }
  }

  @Test(
    "最新の付け替え先が不適格なら、それより古い dev を採る", .timeLimit(.minutes(1)),
    arguments: ["HEAD~1", "deleted", "v1", "origin/feature"])
  func skipsIneligibleNewestReset(startPoint: String) async throws {
    try await withGitRepository { repository in
      try await repository.prepareResetBranches()
      try await repository.git(["branch", "deleted", "main"])
      try await repository.git(["tag", "v1", "main"])
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/origin/feature", "main"])
      try await repository.git(["checkout", "-q", "-B", "feature", "dev"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "c1"])
      try await repository.git(["checkout", "-q", "-B", "feature", startPoint])
      if startPoint == "deleted" {
        try await repository.git(["branch", "-D", "deleted"])
      }
      try await repository.requireReflogSubjects(
        [
          "branch: Reset to " + startPoint, "commit: c1",
          "branch: Reset to dev", "branch: Created from main",
        ],
        of: "refs/heads/feature")
      let resolved = try await repository.gitExitCode([
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", startPoint,
      ])
      switch startPoint {
      case "HEAD~1":
        try #require(resolved.exitCode == 0)
        try #require(resolved.stdout.isEmpty)
      case "deleted":
        try #require(resolved.exitCode == 1)
      case "v1":
        try #require(resolved.exitCode == 0)
        try #require(resolved.stdout == "refs/tags/v1\n")
      default:
        try #require(resolved.exitCode == 0)
        try #require(resolved.stdout == "refs/remotes/origin/feature\n")
      }

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("dev"), source: .forkPoint))
    }
  }

  @Test("付け替え先がすべて不適格なら作成時の local-base を採る", .timeLimit(.minutes(1)))
  func fallsBackToCreatedFrom() async throws {
    try await withGitRepository { repository in
      try await repository.prepareResetBranches(createdFrom: "local-base")
      try await repository.git(["tag", "v1", "dev"])
      try await repository.git(["checkout", "-q", "-B", "feature", "v1"])
      try await repository.requireReflogSubjects(
        ["branch: Reset to v1", "branch: Created from local-base"], of: "refs/heads/feature")
      let resolved = try await repository.gitExitCode([
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", "v1",
      ])
      try #require(resolved.exitCode == 0)
      try #require(resolved.stdout == "refs/tags/v1\n")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("local-base"), source: .forkPoint))
    }
  }

  @Test("付け替え後に rename しても dev を採る", .timeLimit(.minutes(1)))
  func resolvesResetAfterRename() async throws {
    try await withGitRepository { repository in
      try await repository.prepareResetBranches()
      try await repository.git(["checkout", "-q", "-B", "feature", "dev"])
      try await repository.git(["branch", "-m", "feature", "renamed"])
      try await repository.requireReflogSubjects(
        [
          "Branch: renamed refs/heads/feature to refs/heads/renamed",
          "branch: Reset to dev", "branch: Created from main",
        ], of: "refs/heads/renamed")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("dev"), source: .forkPoint))
    }
  }

  @Test("限界: rebase --onto の載せ替え先は採らず作成時の起点を採る", .timeLimit(.minutes(1)))
  func retainsCreatedFromAfterRebaseOnto() async throws {
    try await withGitRepository { repository in
      try await repository.prepareResetBranches(createdFrom: "local-base")
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "c1"])
      try await repository.git(["rebase", "--onto", "other", "main"])
      let other = try await repository.gitExitCode(["rev-parse", "--verify", "other"])
      try #require(other.exitCode == 0)
      let oid = other.stdout.trimmingCharacters(in: .newlines)
      try #require(!oid.isEmpty)
      try await repository.requireReflogSubjects(
        [
          "rebase (finish): refs/heads/feature onto " + oid,
          "commit: c1", "branch: Created from local-base",
        ], of: "refs/heads/feature")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("local-base"), source: .forkPoint))
    }
  }

  @Test("作成の項目が消え最古が commit でも付け替え先の dev を採る", .timeLimit(.minutes(1)))
  func resolvesResetWithoutCreation() async throws {
    try await withGitRepository { repository in
      try await repository.prepareResetBranches()
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "c1"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "c2"])
      try await repository.git(["checkout", "-q", "-B", "feature", "dev"])
      try await repository.git(["reflog", "delete", "refs/heads/feature@{3}"])
      try await repository.requireReflogSubjects(
        ["branch: Reset to dev", "commit: c2", "commit: c1"], of: "refs/heads/feature")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("dev"), source: .forkPoint))
    }
  }
}

extension GitTestRepository {
  fileprivate func prepareResetBranches(createdFrom: String = "main") async throws {
    try await git(["checkout", "-q", "-b", "dev", "main"])
    try await git(["commit", "-q", "--allow-empty", "-m", "dev"])
    try await git(["checkout", "-q", "-b", "other", "dev"])
    try await git(["commit", "-q", "--allow-empty", "-m", "other"])
    if createdFrom != "main" {
      try await git(["branch", createdFrom, "main"])
    }
    try await git(["checkout", "-q", "-b", "feature", createdFrom])
  }

  func requireReflogSubjects(_ subjects: [String], of fullName: String) async throws {
    let result = try await gitExitCode([
      "reflog", "show", "--no-show-signature", "--format=%gs", fullName, "--",
    ])
    try #require(result.exitCode == 0)
    try #require(result.stdout == subjects.joined(separator: "\n") + "\n")
  }
}
