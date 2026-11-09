import TerminalCore
import Testing

@Suite("§3.2 不完全な worktree 一覧の差分計算")
struct WorktreePartialListingTests {
  @Test(
    "一覧に無い Task は detected と観測状態と Active/Inactive を前回のまま保持する",
    arguments: [WorktreeActivation.active, .inactive],
    [WorktreeObservation.reachable, .unreachable, .observationFailed]
  )
  func retainsMissingTask(
    activation: WorktreeActivation, observation: WorktreeObservation
  ) throws {
    let old = try detected("old", branch: "previous", observation: observation)
    let previous = WorktreeInventory(
      projectRoot: nil, taskWorktrees: [TaskWorktree(detected: old, activation: activation)])

    let result = reconcileDetectedWorktrees(
      detected: [], previous: previous, isListingComplete: false)

    #expect(result.inventory == previous)
    #expect(result.unobserved == [old.identity])
    #expect(result.disappeared.isEmpty)
    #expect(result.appeared.isEmpty)
  }

  @Test(
    "一覧に無い Project Root も前回の観測のまま保持する",
    arguments: [WorktreeObservation.reachable, .unreachable, .observationFailed]
  )
  func retainsMissingProjectRoot(observation: WorktreeObservation) throws {
    let root = try detected("root", branch: "main", isProjectRoot: true, observation: observation)
    let task = try detected("task")
    let previous = WorktreeInventory(
      projectRoot: root, taskWorktrees: [TaskWorktree(detected: task, activation: .active)])

    let result = reconcileDetectedWorktrees(
      detected: [task], previous: previous, isListingComplete: false)

    #expect(result.inventory == previous)
    #expect(result.unobserved == [root.identity])
    #expect(result.disappeared.isEmpty)
    #expect(result.appeared.isEmpty)
  }

  @Test("今回検出した値へ更新し、未検出を保持し、新規出現は Inactive にする")
  func mergesDetectedRetainedAndNewWorktrees() throws {
    let oldRoot = try detected("root", branch: "old-main", isProjectRoot: true)
    let newRoot = try detected("root", branch: "main", isProjectRoot: true)
    let oldTask = try detected("updated", branch: "old-branch", observation: .unreachable)
    let newTask = try detected("updated", branch: "new-branch")
    let missing = try detected("missing", branch: "retained")
    let appeared = try detected("new", branch: "new-task")
    let previous = WorktreeInventory(
      projectRoot: oldRoot,
      taskWorktrees: [
        TaskWorktree(detected: oldTask, activation: .active),
        TaskWorktree(detected: missing, activation: .inactive),
      ])

    let result = reconcileDetectedWorktrees(
      detected: [newRoot, appeared, newTask], previous: previous, isListingComplete: false)

    #expect(result.inventory.projectRoot == newRoot)
    #expect(
      result.inventory.taskWorktrees == [
        TaskWorktree(detected: newTask, activation: .active),
        TaskWorktree(detected: missing, activation: .inactive),
        TaskWorktree(detected: appeared, activation: .inactive),
      ])
    #expect(result.unobserved == [missing.identity])
    #expect(result.disappeared.isEmpty)
    #expect(result.appeared == [appeared.identity])
  }

  @Test("完全な一覧は明示指定でも既定でも未検出を消失とし、観測失敗の指定だけ保持する")
  func completeListingPreservesExistingBehavior() throws {
    let root = try detected("root", isProjectRoot: true)
    let missing = try detected("missing")
    let failed = try detected("failed")
    let previous = WorktreeInventory(
      projectRoot: root,
      taskWorktrees: [
        TaskWorktree(detected: missing, activation: .active),
        TaskWorktree(detected: failed, activation: .active),
      ])

    let explicit = reconcileDetectedWorktrees(
      detected: [], previous: previous, unobserved: [failed.worktreePath], isListingComplete: true)
    let implicit = reconcileDetectedWorktrees(
      detected: [], previous: previous, unobserved: [failed.worktreePath])

    #expect(explicit == implicit)
    #expect(explicit.inventory.projectRoot == nil)
    #expect(explicit.inventory.taskWorktrees.map(\.identity) == [failed.identity])
    #expect(explicit.inventory.taskWorktrees.map(\.detected.observation) == [.observationFailed])
    #expect(explicit.inventory.taskWorktrees.map(\.activation) == [.active])
    #expect(explicit.unobserved == [failed.identity])
    #expect(explicit.disappeared == [root.identity, missing.identity])
    #expect(explicit.appeared.isEmpty)
  }

  @Test(
    "部分一覧でも個別の観測失敗は観測失敗に更新し、一覧に無い Task の観測だけを保持する",
    arguments: [WorktreeActivation.active, .inactive],
    [WorktreeObservation.reachable, .unreachable, .observationFailed]
  )
  func entryFailureOverridesPreviousObservationInPartialListing(
    activation: WorktreeActivation, observation: WorktreeObservation
  ) throws {
    let failed = try detected("failed", branch: "failed-branch", observation: observation)
    let missing = try detected("missing", branch: "missing-branch", observation: observation)
    let expectedFailed = try detected(
      "failed", branch: "failed-branch", observation: .observationFailed)
    let previous = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        TaskWorktree(detected: failed, activation: activation),
        TaskWorktree(detected: missing, activation: activation),
      ])

    let result = reconcileDetectedWorktrees(
      detected: [], previous: previous, unobserved: [failed.worktreePath], isListingComplete: false)

    #expect(
      result.inventory.taskWorktrees == [
        TaskWorktree(detected: expectedFailed, activation: activation),
        TaskWorktree(detected: missing, activation: activation),
      ])
    #expect(result.unobserved == [failed.identity, missing.identity])
    #expect(result.appeared.isEmpty)
    #expect(result.disappeared.isEmpty)
  }

  private func detected(
    _ name: String,
    branch: String? = nil,
    isProjectRoot: Bool = false,
    observation: WorktreeObservation = .reachable
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(
        WorktreeIdentity(rawValue: isProjectRoot ? "/repo/.git" : "/repo/.git/worktrees/\(name)")),
      worktreePath: isProjectRoot ? "/repo" : "/wt/\(name)",
      branch: branch, isProjectRoot: isProjectRoot, observation: observation)
  }
}
