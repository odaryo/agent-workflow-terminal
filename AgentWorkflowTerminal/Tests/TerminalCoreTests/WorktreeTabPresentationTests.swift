import Testing

@testable import TerminalCore

@Suite("タブ列と pane 観測の対象")
struct WorktreeTabPresentationTests {
  @Test("タブ列は Active だけを含み、Inactive の一覧と排他になる")
  func splitsByActivation() throws {
    let inventory = WorktreeInventory(
      projectRoot: try root(),
      taskWorktrees: [
        try task("active", activation: .active),
        try task("inactive", activation: .inactive),
        try task("inactive-2", activation: .inactive),
      ])

    #expect(inventory.tabbedTaskWorktrees.map(\.identity) == [try identity("active")])
    #expect(
      inventory.inactiveTaskWorktrees.map(\.identity)
        == [try identity("inactive"), try identity("inactive-2")])
  }

  @Test("到達不能でも Active ならタブ列に残す")
  func keepsUnreachableActiveTab() throws {
    let inventory = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        try task("unreachable", activation: .active, observation: .unreachable)
      ])

    #expect(inventory.tabbedTaskWorktrees.map(\.identity) == [try identity("unreachable")])
  }

  @Test("Active かつ到達可能な Task worktree だけ pane を観測する")
  func observesOnlyReachableActiveTask() throws {
    let inventory = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        try task("active", activation: .active),
        try task("inactive", activation: .inactive),
        try task("active-unreachable", activation: .active, observation: .unreachable),
        try task("active-unobserved", activation: .active, observation: .observationFailed),
      ])

    #expect(inventory.observesPaneStates(of: try identity("active")))
    #expect(!inventory.observesPaneStates(of: try identity("inactive")))
    #expect(!inventory.observesPaneStates(of: try identity("active-unreachable")))
    #expect(!inventory.observesPaneStates(of: try identity("active-unobserved")))
  }

  @Test("到達可能な Project Root は観測し、到達不能なら観測しない")
  func observesReachableProjectRoot() throws {
    let reachable = WorktreeInventory(projectRoot: try root(), taskWorktrees: [])
    #expect(reachable.observesPaneStates(of: try identity(nil)))

    let unreachable = WorktreeInventory(
      projectRoot: try root(observation: .unreachable), taskWorktrees: [])
    #expect(!unreachable.observesPaneStates(of: try identity(nil)))
  }

  @Test("未知の identity は観測しない")
  func rejectsUnknownIdentity() throws {
    let inventory = WorktreeInventory(
      projectRoot: try root(), taskWorktrees: [try task("active", activation: .active)])

    #expect(!inventory.observesPaneStates(of: try identity("unknown")))
  }
}

private func identity(_ name: String?) throws -> WorktreeIdentity {
  let path = name.map { "/repo/.git/worktrees/\($0)" } ?? "/repo/.git"
  return try #require(WorktreeIdentity(rawValue: path))
}

private func root(
  observation: WorktreeObservation = .reachable
) throws -> DetectedWorktree {
  DetectedWorktree(
    identity: try identity(nil),
    worktreePath: "/repo",
    branch: "main",
    isProjectRoot: true,
    observation: observation
  )
}

private func task(
  _ name: String,
  activation: WorktreeActivation,
  observation: WorktreeObservation = .reachable
) throws -> TaskWorktree {
  TaskWorktree(
    detected: DetectedWorktree(
      identity: try identity(name),
      worktreePath: "/work/\(name)",
      branch: name,
      isProjectRoot: false,
      observation: observation
    ),
    activation: activation
  )
}
