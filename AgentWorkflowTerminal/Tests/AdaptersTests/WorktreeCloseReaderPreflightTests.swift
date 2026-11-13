import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§3.4 削除を含む Close の読み直しの防御")
struct WorktreeCloseReaderPreflightTests {
  @Test("削除する計画で branch が無ければ git を読まず detached として拒否する", arguments: [true, false])
  func refusesMissingPlannedBranchWithoutReadingGit(deletesBranch: Bool) async throws {
    let git = gitStub()
    let reader = try reader(git: git)

    let refusal = await reader.preflightRefusal(
      plannedBranch: nil, plannedTip: deletesBranch ? try inspectedTip() : nil,
      removesWorktree: true)

    #expect(refusal == .detachedHead)
    #expect(await git.invocations.isEmpty)
  }

  @Test("branch 削除だけでも detached HEAD を拒否する")
  func refusesDetachedHeadForBranchDeletionOnly() async throws {
    let reader = try reader(git: gitStub(head: gitNotFound))

    let refusal = await reader.preflightRefusal(
      plannedBranch: "topic", plannedTip: try inspectedTip(), removesWorktree: false)

    #expect(refusal == .detachedHead)
  }

  @Test("branch 削除だけでも先端の移動を拒否する")
  func comparesTipForBranchDeletionOnly() async throws {
    let moved = try #require(CommitObjectID(String(repeating: "b", count: 40)))
    let reader = try reader(git: gitStub(tip: tipOutput(moved.rawValue)))

    let refusal = await reader.preflightRefusal(
      plannedBranch: "topic", plannedTip: try inspectedTip(), removesWorktree: false)

    #expect(refusal == .branchTipMoved(planned: try inspectedTip(), current: moved))
  }

  private func reader(git: WorktreeCloseGitStub) throws -> GitWorktreeProgressReader {
    let directory = "/repo/.git/worktrees/feature-a"
    let runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: directory),
      processRunner: git, executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: [:], isExecutableFile: { _ in true })
    return GitWorktreeProgressReader(
      runner: runner, worktreeRunner: runner,
      identity: try #require(WorktreeIdentity(rawValue: directory)), worktreePath: "/repo/wt",
      fileExists: { _ in false }, isDirectory: { _ in false })
  }
}
