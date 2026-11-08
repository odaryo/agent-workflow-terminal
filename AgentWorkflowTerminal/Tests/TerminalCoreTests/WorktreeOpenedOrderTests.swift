import TerminalCore
import Testing

@Suite("worktreeを開いた順に維持する (設計書 §13)")
struct WorktreeOpenedOrderTests {

  // MARK: - Helpers

  private func detected(
    _ name: String,
    branch: String? = nil,
    isProjectRoot: Bool = false,
    isReachable: Bool = true
  ) throws -> DetectedWorktree {
    let path = isProjectRoot ? "/repo/.git" : "/repo/.git/worktrees/\(name)"
    return DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: path)),
      worktreePath: isProjectRoot ? "/repo" : "/wt/\(name)",
      branch: branch,
      isProjectRoot: isProjectRoot,
      isReachable: isReachable
    )
  }

  private func inventory(
    projectRoot: DetectedWorktree? = nil,
    _ entries: [(DetectedWorktree, WorktreeActivation)]
  ) -> WorktreeInventory {
    WorktreeInventory(
      projectRoot: projectRoot,
      taskWorktrees: entries.map { TaskWorktree(detected: $0.0, activation: $0.1) }
    )
  }

  @Test("検出順が変わっても前回のTask worktreeの順を維持する (設計書 §13)")
  func taskWorktreesKeepPreviousOrder() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")

    let result = reconcileDetectedWorktrees(
      detected: [alpha, beta],
      previous: inventory([(beta, .active), (alpha, .inactive)])
    )

    #expect(result.inventory.taskWorktrees.map(\.identity) == [beta.identity, alpha.identity])
    #expect(result.appeared.isEmpty)
    #expect(result.disappeared.isEmpty)
    #expect(result.unobserved.isEmpty)
  }

  @Test("前回に無いTask worktreeを検出順で末尾へ足す (設計書 §13)")
  func newTaskWorktreesFollowPreviousOnesInDetectionOrder() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")
    let delta = try detected("delta")

    let result = reconcileDetectedWorktrees(
      detected: [gamma, alpha, delta, beta],
      previous: inventory([(beta, .active), (alpha, .inactive)])
    )

    #expect(
      result.inventory.taskWorktrees.map(\.identity)
        == [beta.identity, alpha.identity, gamma.identity, delta.identity])
    #expect(result.appeared == [gamma.identity, delta.identity])
    #expect(result.disappeared.isEmpty)
    #expect(result.unobserved.isEmpty)
  }

  @Test("観測に失敗したTask worktreeの位置を維持する (設計書 §13)")
  func unobservedTaskWorktreeKeepsPreviousPosition() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")

    let result = reconcileDetectedWorktrees(
      detected: [alpha, gamma],
      previous: inventory([(alpha, .active), (beta, .active), (gamma, .inactive)]),
      unobserved: [beta.worktreePath]
    )

    #expect(
      result.inventory.taskWorktrees.map(\.identity)
        == [alpha.identity, beta.identity, gamma.identity])
    #expect(
      result.inventory.taskWorktrees.map(\.detected.observation)
        == [.reachable, .observationFailed, .reachable])
    #expect(result.appeared.isEmpty)
    #expect(result.disappeared.isEmpty)
    #expect(result.unobserved == [beta.identity])
  }

  @Test("消失したTask worktreeだけを外して前回の順を維持する (設計書 §13)")
  func disappearedTaskWorktreeLeavesRemainingOrderUnchanged() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")

    let result = reconcileDetectedWorktrees(
      detected: [alpha, gamma],
      previous: inventory([(alpha, .active), (beta, .inactive), (gamma, .active)])
    )

    #expect(result.inventory.taskWorktrees.map(\.identity) == [alpha.identity, gamma.identity])
    #expect(result.appeared.isEmpty)
    #expect(result.disappeared == [beta.identity])
    #expect(result.unobserved.isEmpty)
  }

  @Test("InactiveからActiveにするとactivationを変えて末尾へ移す (設計書 §13)")
  func activatingInactiveWorktreeMovesItToEnd() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")
    let worktrees = inventory([(alpha, .active), (beta, .inactive), (gamma, .inactive)])
      .taskWorktrees

    let result = applyingActivation(.active, of: beta.identity, to: worktrees)

    #expect(
      result == [
        worktrees[0], worktrees[2], TaskWorktree(detected: beta, activation: .active),
      ])
  }

  @Test("ActiveからInactiveにしても位置を変えない (設計書 §13)")
  func deactivatingActiveWorktreeKeepsItsPosition() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")
    let worktrees = inventory([(alpha, .inactive), (beta, .active), (gamma, .active)]).taskWorktrees

    let result = applyingActivation(.inactive, of: beta.identity, to: worktrees)

    #expect(
      result == [
        worktrees[0], TaskWorktree(detected: beta, activation: .inactive), worktrees[2],
      ])
  }

  @Test("同じactivationを指定しても配列を変えない", arguments: [WorktreeActivation.active, .inactive])
  func applyingSameActivationLeavesWorktreesUnchanged(activation: WorktreeActivation) throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let worktrees = inventory([(alpha, activation), (beta, .active)]).taskWorktrees

    #expect(applyingActivation(activation, of: alpha.identity, to: worktrees) == worktrees)
  }

  @Test("知らないIDのactivationを指定しても配列を変えない", arguments: [WorktreeActivation.active, .inactive])
  func applyingActivationToUnknownIdentityLeavesWorktreesUnchanged(
    activation: WorktreeActivation
  ) throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let unknown = try detected("unknown")
    let worktrees = inventory([(alpha, .active), (beta, .inactive)]).taskWorktrees

    #expect(applyingActivation(activation, of: unknown.identity, to: worktrees) == worktrees)
  }
}
