import TerminalCore
import Testing

@Suite("Close の削除を妨げる条件 (設計書 §3.4)")
struct WorktreeClosePlanRemovalObstaclesTests {
  private static let everyChoice: [WorktreeCloseChoice] = [
    .hideFromUI, .terminateSession(.keepWorktree),
    .terminateSession(.removeWorktree(.keepBranch)),
    .terminateSession(.removeWorktree(.deleteBranch)),
  ]

  private static let removalCases: [(WorktreeRemovalObstacles, WorktreeClosePlanError)] = [
    (.unknown, .removalObstaclesUnknown),
    (
      .observed(lockReason: "portable\nvolume", populatedSubmodules: []),
      .worktreeLocked(reason: "portable\nvolume")
    ),
    (.observed(lockReason: "", populatedSubmodules: []), .worktreeLocked(reason: "")),
    (
      .observed(lockReason: nil, populatedSubmodules: [], hasAdministrativeModules: true),
      .worktreeContainsSubmodules(paths: [], hasAdministrativeModules: true)
    ),
    (
      .observed(lockReason: "locked", populatedSubmodules: [], hasAdministrativeModules: true),
      .worktreeLocked(reason: "locked")
    ),
  ]

  @Test("3・4は削除の妨げを確認より先に拒否する (設計書 §3.4)", arguments: removalCases)
  func rejectsRemovalObstaclesBeforeConfirmation(
    obstacles: WorktreeRemovalObstacles, expected: WorktreeClosePlanError
  ) throws {
    let target = try worktree()
    let report = WorktreeOperationProgressReport(
      target: target, progress: .observed([]), removalObstacles: obstacles)
    for choice in Self.everyChoice.suffix(2) {
      for confirmation in [nil, self.confirmation(for: target, merge: try merged(.ancestor))] {
        #expect(throws: expected) {
          try planWorktreeClose(
            worktree: target, progress: report, choice: choice, confirmation: confirmation)
        }
      }
    }
  }

  @Test("gitlink のパスを伴う submodule の拒否を返す (設計書 §3.4)")
  func rejectsPopulatedSubmodulePaths() throws {
    let target = try worktree()
    let path = try #require(WorktreeRelativePath("libs/sub"))
    let report = WorktreeOperationProgressReport(
      target: target, progress: .observed([]),
      removalObstacles: .observed(lockReason: nil, populatedSubmodules: [path]))
    for choice in Self.everyChoice.suffix(2) {
      #expect(
        throws: WorktreeClosePlanError.worktreeContainsSubmodules(
          paths: [path], hasAdministrativeModules: false)
      ) {
        try planWorktreeClose(worktree: target, progress: report, choice: choice, confirmation: nil)
      }
    }
  }

  @Test("1・2は削除の妨げを読まず同じ計画を返す (設計書 §3.4)", arguments: removalCases)
  func permitsNonremovalChoicesDespiteObstacles(
    obstacles: WorktreeRemovalObstacles, expected: WorktreeClosePlanError
  ) throws {
    let target = try worktree()
    let path = try #require(WorktreeRelativePath("libs/sub"))
    for observation in [obstacles, .observed(lockReason: nil, populatedSubmodules: [path])] {
      for choice in Self.everyChoice.prefix(2) {
        let plan = try planWorktreeClose(
          worktree: target,
          progress: .init(target: target, progress: .observed([]), removalObstacles: observation),
          choice: choice, confirmation: nil)
        let baseline = try planWorktreeClose(
          worktree: target, progress: idle(target), choice: choice, confirmation: nil)
        #expect(plan == baseline)
      }
    }
  }

  private func idle(_ worktree: DetectedWorktree) -> WorktreeOperationProgressReport {
    WorktreeOperationProgressReport(
      target: worktree, progress: .observed([]),
      removalObstacles: .observed(lockReason: nil, populatedSubmodules: []))
  }

  private func worktree(
    _ identity: String = "/repo/.git/worktrees/feature-a",
    branch: String? = "topic",
    isProjectRoot: Bool = false
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: identity)),
      worktreePath: "/repo/wt", branch: branch, isProjectRoot: isProjectRoot)
  }

  private func confirmation(
    for worktree: DetectedWorktree,
    uncommitted: UncommittedChangesStatus = .absent,
    ignored: IgnoredFilesStatus = .absent,
    merge: BranchMergeStatus = .unmerged,
    defaultBranch: DefaultBranchResolution = .originHead(branch: "main"),
    continuation: WorktreeRemovalConfirmation.Continuation = .withoutForce
  ) -> WorktreeRemovalConfirmation {
    let report = WorktreeCloseInspectionReport(
      target: worktree,
      inspection: WorktreeCloseInspection(
        uncommittedChanges: uncommitted, ignoredFiles: ignored, unpushedCommits: .absent,
        branchMerge: merge),
      defaultBranch: defaultBranch)
    return WorktreeRemovalConfirmation(report: report, continuation: continuation)
  }
}
