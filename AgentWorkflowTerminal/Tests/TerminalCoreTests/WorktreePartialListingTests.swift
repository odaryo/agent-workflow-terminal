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

  @Test("部分一覧で、保持していた Task と同じパスに別の安定 ID が現れたら、保持していた側を消失にする")
  func detectedWorktreeAtRetainedPathReplacesIt() throws {
    let removed = try detected("reused", worktreePath: "/wt/reused")
    let replacement = try detected("reused1", worktreePath: "/wt/reused")
    let other = try detected("other")
    let previous = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        TaskWorktree(detected: removed, activation: .active),
        TaskWorktree(detected: other, activation: .active),
      ])

    let result = reconcileDetectedWorktrees(
      detected: [replacement], previous: previous, isListingComplete: false)

    #expect(result.disappeared == [removed.identity])
    #expect(result.unobserved == [other.identity])
    #expect(result.appeared == [replacement.identity])
    #expect(
      result.inventory.taskWorktrees.map(\.identity) == [other.identity, replacement.identity])
    #expect(
      result.inventory.taskWorktrees.filter { $0.detected.worktreePath == "/wt/reused" }.count == 1)
  }

  @Test("部分一覧でも、git が prunable と明示した未検出の Task は消失にする")
  func prunableTaskDisappearsInPartialListing() throws {
    let pruned = try detected("pruned")
    let missing = try detected("missing")
    let previous = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        TaskWorktree(detected: pruned, activation: .active),
        TaskWorktree(detected: missing, activation: .active),
      ])

    let result = reconcileDetectedWorktrees(
      detected: [], previous: previous, isListingComplete: false, prunable: [pruned.identity])

    #expect(result.disappeared == [pruned.identity])
    #expect(result.unobserved == [missing.identity])
    #expect(result.inventory.taskWorktrees.map(\.identity) == [missing.identity])
  }

  /// 入れないだけの到達不能は prunable でも保持する (設計書 §3.2.1、Issue #496)。
  @Test("prunable でも今回検出した Task は消失にせず、検出した値へ更新する")
  func detectedPrunableTaskIsRetained() throws {
    let before = try detected("locked-out")
    let unreachable = try detected("locked-out", observation: .unreachable)
    let previous = WorktreeInventory(
      projectRoot: nil, taskWorktrees: [TaskWorktree(detected: before, activation: .active)])

    let result = reconcileDetectedWorktrees(
      detected: [unreachable], previous: previous, isListingComplete: false,
      prunable: [before.identity])

    #expect(result.disappeared.isEmpty)
    #expect(
      result.inventory.taskWorktrees == [TaskWorktree(detected: unreachable, activation: .active)])
  }

  @Test("§3.2 管理ディレクトリの消失を挟んで同じ安定 ID が再出現したら Inactive にする (#870 T1)")
  func removedTaskReappearsInactiveDuringPersistentIncompleteListing() throws {
    let wt1 = try detected("wt1")
    let wt2 = try detected("wt2")
    let wt3 = try detected("wt3")
    let previous = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [wt1, wt2, wt3].map { TaskWorktree(detected: $0, activation: .active) })

    let omitted = reconcileDetectedWorktrees(
      detected: [wt1, wt3], previous: previous, isListingComplete: false, removed: [])

    #expect(omitted.inventory == previous)
    #expect(omitted.unobserved == [wt2.identity])
    #expect(omitted.disappeared.isEmpty)

    let removed = reconcileDetectedWorktrees(
      detected: [wt1], previous: omitted.inventory, isListingComplete: false,
      removed: [wt3.identity])

    #expect(removed.disappeared == [wt3.identity])
    #expect(removed.unobserved == [wt2.identity])
    #expect(
      removed.inventory.taskWorktrees
        == [wt1, wt2].map {
          TaskWorktree(detected: $0, activation: .active)
        })

    let fresh = try detected("wt3", branch: "fresh")
    let recreated = reconcileDetectedWorktrees(
      detected: [wt1, fresh], previous: removed.inventory, isListingComplete: false, removed: [])

    #expect(recreated.appeared == [wt3.identity])
    #expect(recreated.unobserved == [wt2.identity])
    #expect(recreated.disappeared.isEmpty)
    #expect(
      recreated.inventory.taskWorktrees == [
        TaskWorktree(detected: wt1, activation: .active),
        TaskWorktree(detected: wt2, activation: .active),
        TaskWorktree(detected: fresh, activation: .inactive),
      ])
  }

  @Test(
    "removed でも今回検出した Task は検出値へ更新し activation を保つ (#870 T2)",
    arguments: [WorktreeActivation.active, .inactive])
  func detectedRemovedTaskIsUpdated(activation: WorktreeActivation) throws {
    let before = try detected("wt3", branch: "old", observation: .unreachable)
    let updated = try detected("wt3", branch: "fresh")
    let previous = WorktreeInventory(
      projectRoot: nil, taskWorktrees: [TaskWorktree(detected: before, activation: activation)])

    let result = reconcileDetectedWorktrees(
      detected: [updated], previous: previous, isListingComplete: false,
      removed: [before.identity])

    #expect(result.disappeared.isEmpty)
    #expect(result.unobserved.isEmpty)
    #expect(result.appeared.isEmpty)
    #expect(
      result.inventory.taskWorktrees == [TaskWorktree(detected: updated, activation: activation)])
  }

  @Test("完全な一覧で removed を渡しても結果は変わらない (#870 T3)")
  func removedDoesNotChangeCompleteListing() throws {
    let wt1 = try detected("wt1")
    let wt2 = try detected("wt2")
    let previous = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [wt1, wt2].map { TaskWorktree(detected: $0, activation: .active) })

    let withoutRemoved = reconcileDetectedWorktrees(
      detected: [wt1], previous: previous, isListingComplete: true)
    let withRemoved = reconcileDetectedWorktrees(
      detected: [wt1], previous: previous, isListingComplete: true,
      removed: [wt1.identity, wt2.identity])

    #expect(withRemoved == withoutRemoved)
    #expect(withRemoved.disappeared == [wt2.identity])
  }

  private func detected(
    _ name: String,
    branch: String? = nil,
    isProjectRoot: Bool = false,
    observation: WorktreeObservation = .reachable,
    worktreePath: String? = nil
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(
        WorktreeIdentity(rawValue: isProjectRoot ? "/repo/.git" : "/repo/.git/worktrees/\(name)")),
      worktreePath: worktreePath ?? (isProjectRoot ? "/repo" : "/wt/\(name)"),
      branch: branch, isProjectRoot: isProjectRoot, observation: observation)
  }
}
