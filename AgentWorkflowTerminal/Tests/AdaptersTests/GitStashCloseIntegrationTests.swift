import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§3.4 実 git の worktree の branch に対する stash 検査")
struct GitStashCloseIntegrationTests {
  @Test("linked worktree で作った stash を Close の検査結果に件数付きで返す")
  func detectsLinkedWorktreeStash() async throws {
    try await withGitRepository { repository in
      try await addTrackedFile(in: repository)
      try await repository.git(["worktree", "add", "-q", "-b", "feature/x", "../wt"])
      try await stashChange(in: repository, worktree: "wt")

      let result = try await inspectLinkedWorktree(in: repository)

      #expect(result.report.inspection.branchStashes == .present(count: 1))
      #expect(result.report.inspection.undeterminedStashCount == 0)
      #expect(result.report.inspection.uncommittedChanges == .absent)
      #expect(result.failures.isEmpty)
    }
  }

  @Test("共有 stash に別の branch のものしか無ければ無いと返す")
  func excludesOtherBranchStash() async throws {
    try await withGitRepository { repository in
      try await addTrackedFile(in: repository)
      try await repository.git(["worktree", "add", "-q", "-b", "feature/x", "../wt"])
      try await stashChange(in: repository, worktree: "main")

      let result = try await inspectLinkedWorktree(in: repository)

      #expect(result.report.inspection.branchStashes == .absent)
      #expect(result.report.inspection.undeterminedStashCount == 0)
      #expect(result.failures.isEmpty)
    }
  }

  @Test("detached worktree の stash をその worktree のものと決めず対象外にする")
  func excludesDetachedWorktree() async throws {
    try await withGitRepository { repository in
      try await addTrackedFile(in: repository)
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt", "HEAD"])
      try await stashChange(in: repository, worktree: "wt")

      let result = try await inspectLinkedWorktree(in: repository, expectedBranch: nil)
      #expect(result.report.inspection.branchStashes == .notApplicable)
      #expect(result.report.inspection.undeterminedStashCount == 1)
      #expect(result.failures.isEmpty)
    }
  }

  @Test(
    "stash store の既定の件名を target の branch の有無によらず別に数える", arguments: [false, true])
  func countsStoredStash(detached: Bool) async throws {
    try await withGitRepository { repository in
      try await addTrackedFile(in: repository)
      let branchArguments = detached ? ["--detach"] : ["-b", "feature/x"]
      try await repository.git(["worktree", "add", "-q"] + branchArguments + ["../wt", "HEAD"])
      try "changed\n".write(
        to: repository.mainWorktree.appending(path: "tracked.txt"), atomically: true,
        encoding: .utf8)
      let created = try await repository.gitExitCode(["stash", "create"])
      try #require(created.exitCode == 0)
      let stashObject = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      try #require(!stashObject.isEmpty)
      try await repository.git(["stash", "store", stashObject])

      let result = try await inspectLinkedWorktree(
        in: repository, expectedBranch: detached ? nil : "feature/x")

      #expect(result.report.inspection.branchStashes == (detached ? .notApplicable : .absent))
      let undeterminedStashCount: Int = result.report.inspection.undeterminedStashCount
      #expect(undeterminedStashCount == 1)
      #expect(result.failures.isEmpty)
    }
  }

  private func addTrackedFile(in repository: GitTestRepository) async throws {
    try "base\n".write(
      to: repository.mainWorktree.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
    try await repository.git(["add", "tracked.txt"])
    try await repository.git(["commit", "-q", "-m", "base"])
  }

  private func stashChange(in repository: GitTestRepository, worktree: String) async throws {
    try "changed\n".write(
      to: repository.root.appending(path: worktree).appending(path: "tracked.txt"),
      atomically: true, encoding: .utf8)
    try await repository.git(["stash", "push", "-q"], in: worktree)
  }

  private func inspectLinkedWorktree(
    in repository: GitTestRepository, expectedBranch: String? = "feature/x"
  ) async throws -> GitCloseSafetyInspectionResult {
    let target = try #require(
      try await repository.detector().scan().detected.first { !$0.isProjectRoot })
    #expect(target.branch == expectedBranch)
    let inspector = GitCloseSafetyInspector(
      runner: try repository.runner(globalConfig: "", in: "wt"), target: target)
    return await inspector.inspect(projectRootBranch: "main")
  }
}
