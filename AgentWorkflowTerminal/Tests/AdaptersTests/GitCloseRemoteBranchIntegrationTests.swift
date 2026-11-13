import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§3.4 detached HEAD を含む remote branch の実 git 観測")
struct GitCloseRemoteBranchIntegrationTests {
  @Test("remote branch の先端より前の HEAD も含むと判定し、短縮名を git の順で返す")
  func observesRemoteBranchesContainingAncestor() async throws {
    try await withGitRepository { repository in
      try await repository.addBareCloseRemote()
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt-detached", "HEAD"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "remote descendant"])
      try await repository.git([
        "push", "-q", "origin", "HEAD:refs/heads/feature/x", "HEAD:refs/heads/topic",
      ])

      let result = try await inspect(repository, worktreeName: "wt-detached")

      #expect(
        result.remoteBranchesContainingHead == .observed(["origin/feature/x", "origin/topic"]))
      #expect(result.failures.isEmpty)
    }
  }

  @Test("remote branch があっても detached の新しい commit を含まなければ空の観測を返す")
  func observesNoContainingRemoteBranch() async throws {
    try await withGitRepository { repository in
      try await repository.addBareCloseRemote()
      try await repository.git(["push", "-q", "origin", "HEAD:refs/heads/main"])
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt-detached", "HEAD"])
      try await repository.git(
        ["commit", "-q", "--allow-empty", "-m", "unpublished"], in: "wt-detached")

      let result = try await inspect(repository, worktreeName: "wt-detached")

      #expect(result.remoteBranchesContainingHead == .observed([]))
      #expect(result.failures.isEmpty)
    }
  }

  @Test("origin/HEAD symref を除き、HEAD を含む remote branch を省略せず返す")
  func excludesRemoteHeadSymrefWithoutLimitingBranches() async throws {
    try await withGitRepository { repository in
      try await repository.addBareCloseRemote()
      try await repository.git([
        "push", "-q", "origin", "HEAD:refs/heads/main", "HEAD:refs/heads/feature/x",
        "HEAD:refs/heads/topic",
      ])
      try await repository.git(["remote", "set-head", "origin", "main"])
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt-detached", "HEAD"])

      let result = try await inspect(repository, worktreeName: "wt-detached")

      #expect(
        result.remoteBranchesContainingHead
          == .observed(["origin/feature/x", "origin/main", "origin/topic"]))
      #expect(result.failures.isEmpty)
    }
  }

  @Test("公開 initializer は replace ref が偽装した remote branch の包含を無視する")
  func publicInitializerIgnoresReplaceRefs() async throws {
    try await withGitRepository { repository in
      try await repository.addBareCloseRemote()
      try await repository.git(["push", "-q", "origin", "HEAD:refs/heads/kp/with-base"])
      let remoteTip = try await repository.branchTip("main")
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt-detached", "HEAD"])
      try await repository.git(
        ["commit", "-q", "--allow-empty", "-m", "local only"], in: "wt-detached")
      let localTip = try await repository.gitExitCode(["rev-parse", "HEAD"], in: "wt-detached")
      let tree = try await repository.gitExitCode(["rev-parse", "HEAD^{tree}"], in: "wt-detached")
      try #require(localTip.exitCode == 0)
      try #require(tree.exitCode == 0)
      let replacement = try await repository.gitExitCode([
        "commit-tree", tree.stdout.trimmingCharacters(in: .newlines),
        "-p", localTip.stdout.trimmingCharacters(in: .newlines), "-m", "replacement",
      ])
      try #require(replacement.exitCode == 0)
      try await repository.git([
        "replace", remoteTip.rawValue, replacement.stdout.trimmingCharacters(in: .newlines),
      ])
      let containsArguments = [
        "for-each-ref", "--contains", "HEAD", "--format=%(refname)", "refs/remotes/",
      ]
      let rewritten = try await repository.gitExitCode(containsArguments, in: "wt-detached")
      #expect(rewritten.exitCode == 0)
      #expect(rewritten.stdout == "refs/remotes/origin/kp/with-base\n")
      let original = try await repository.gitExitCode(
        containsArguments, in: "wt-detached",
        additionalEnvironment: [
          "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null/grafts",
        ])
      #expect(original.exitCode == 0)
      #expect(original.stdout.isEmpty)
      let target = try #require(
        try await repository.detector().scan().detected.first {
          $0.worktreePath == repository.root.appending(path: "wt-detached").path
        })
      #expect(target.branch == nil)
      let inspector = try GitCloseSafetyInspector(
        target: target, processRunner: ConfigIsolatedGitProcessRunner())

      let result = await inspector.inspect(projectRootBranch: "main")

      #expect(result.remoteBranchesContainingHead == .observed([]))
      #expect(result.failures.isEmpty)
    }
  }

  @Test("branch のある worktree は remote に HEAD があっても対象外")
  func doesNotApplyToAttachedHead() async throws {
    try await withGitRepository { repository in
      try await repository.addBareCloseRemote()
      try await repository.git(["push", "-q", "origin", "HEAD:refs/heads/main"])
      try await repository.git(["worktree", "add", "-q", "-b", "topic", "../wt-topic", "HEAD"])

      let result = try await inspect(repository, worktreeName: "wt-topic")

      #expect(result.remoteBranchesContainingHead == .notApplicable)
      #expect(result.failures.isEmpty)
    }
  }

  private func inspect(
    _ repository: GitTestRepository, worktreeName: String
  ) async throws -> GitCloseSafetyInspectionResult {
    let target = try #require(
      try await repository.detector().scan().detected.first {
        $0.worktreePath == repository.root.appending(path: worktreeName).path
      })
    #expect(!target.isProjectRoot)
    #expect((target.branch == nil) == (worktreeName == "wt-detached"))
    let inspector = GitCloseSafetyInspector(
      runner: try repository.runner(
        globalConfig: "", in: worktreeName, ignoresHistoryRewrites: true), target: target)
    return await inspector.inspect(projectRootBranch: "main")
  }
}

extension GitTestRepository {
  fileprivate func addBareCloseRemote() async throws {
    let remote = root.appending(path: "remote.git")
    try await git(["init", "--bare", "-q", remote.path])
    try await git(["remote", "add", "origin", remote.path])
  }
}
