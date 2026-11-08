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
