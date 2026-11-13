import TerminalCore
import Testing

@Suite("§3.4 detached HEAD の Close 選択肢")
struct WorktreeDetachedClosePlanTests {
  private static let everyChoice: [WorktreeCloseChoice] = [
    .hideFromUI, .terminateSession(.keepWorktree),
    .terminateSession(.removeWorktree(.keepBranch)),
    .terminateSession(.removeWorktree(.deleteBranch)),
  ]

  @Test(
    "detached でも選択肢1・2は確認なしで計画できる",
    arguments: [
      (WorktreeCloseChoice.hideFromUI, [WorktreeCloseStep]()),
      (.terminateSession(.keepWorktree), [.terminateSession]),
    ])
  func plansWithoutRemoval(choice: WorktreeCloseChoice, steps: [WorktreeCloseStep]) throws {
    let target = try detached()

    let plan = try planWorktreeClose(
      worktree: target, progress: progress(for: target, .observed([])), choice: choice,
      confirmation: nil)

    let branch: String? = plan.branch
    #expect(branch == nil)
    #expect(plan.worktree == target.identity)
    #expect(plan.steps == steps)
  }

  @Test(
    "detached で作業途中なら全選択肢で途中状態を優先する",
    arguments: everyChoice, WorktreeInProgressOperation.allCases)
  func refusesOperationsBeforeDetachedHead(
    choice: WorktreeCloseChoice, operation: WorktreeInProgressOperation
  ) throws {
    let target = try detached()

    #expect(throws: WorktreeClosePlanError.operationInProgress([operation])) {
      try planWorktreeClose(
        worktree: target, progress: progress(for: target, .observed([operation])), choice: choice,
        confirmation: nil)
    }
  }

  @Test("detached でも途中状態の観測不能を優先する", arguments: everyChoice)
  func refusesUnknownProgressBeforeDetachedHead(choice: WorktreeCloseChoice) throws {
    let target = try detached()

    #expect(throws: WorktreeClosePlanError.operationProgressUnknown) {
      try planWorktreeClose(
        worktree: target, progress: progress(for: target, .unknown), choice: choice,
        confirmation: nil)
    }
  }

  @Test("detached でも別 worktree の途中状態を優先して拒否する", arguments: everyChoice)
  func refusesAnotherWorktreeProgressBeforeDetachedHead(choice: WorktreeCloseChoice) throws {
    let target = try detached()
    let other = try detached(identity: "/repo/.git/worktrees/other")

    #expect(
      throws: WorktreeClosePlanError.progressReportIsForAnotherWorktree(
        report: other.identity, target: target.identity)
    ) {
      try planWorktreeClose(
        worktree: target, progress: progress(for: other, .observed([])), choice: choice,
        confirmation: nil)
    }
  }

  @Test(
    "途中状態の無い detached の選択肢3・4は確認より先に拒否する",
    arguments: [
      WorktreeCloseChoice.terminateSession(.removeWorktree(.keepBranch)),
      .terminateSession(.removeWorktree(.deleteBranch)),
    ])
  func refusesRemovalForDetachedHead(choice: WorktreeCloseChoice) throws {
    let target = try detached()

    #expect(throws: WorktreeClosePlanError.detachedHeadIsNotRemovable) {
      try planWorktreeClose(
        worktree: target, progress: progress(for: target, .observed([])), choice: choice,
        confirmation: nil)
    }
  }

  private func detached(
    identity: String = "/repo/.git/worktrees/detached"
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: identity)), worktreePath: "/repo/wt",
      branch: nil, isProjectRoot: false)
  }

  private func progress(
    for target: DetectedWorktree, _ state: WorktreeOperationProgress
  ) -> WorktreeOperationProgressReport {
    .init(
      target: target, progress: state,
      removalObstacles: .observed(lockReason: nil, populatedSubmodules: []))
  }
}
