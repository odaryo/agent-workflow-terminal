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

  /// Project Root の分岐を「Task worktree が1件も無い」構成でしか押さえないと、その分岐に
  /// `taskWorktrees.isEmpty` を足す変異が生き残る (#237 のレビュー m-1)。
  @Test("Task worktree が並んでいても Project Root は観測する")
  func observesProjectRootAlongsideTasks() throws {
    let inventory = WorktreeInventory(
      projectRoot: try root(),
      taskWorktrees: [
        try task("active", activation: .active),
        try task("inactive", activation: .inactive),
      ])

    #expect(inventory.observesPaneStates(of: try identity(nil)))
  }

  @Test("未知の identity は観測しない")
  func rejectsUnknownIdentity() throws {
    let inventory = WorktreeInventory(
      projectRoot: try root(), taskWorktrees: [try task("active", activation: .active)])

    #expect(!inventory.observesPaneStates(of: try identity("unknown")))
  }

  @Test("初回スキャンが終わるまでは何も案内しない")
  func staysSilentBeforeInitialScan() {
    let scanning = WorktreeInventory(projectRoot: nil, taskWorktrees: [])

    #expect(
      scanning.tabEmptyState(hasSelection: false, didCompleteInitialScan: false) == nil)
    #expect(
      scanning.tabEmptyState(hasSelection: false, didCompleteInitialScan: true) == .noWorktrees)
  }

  @Test("選択があれば案内しない")
  func staysSilentWithSelection() throws {
    let inventory = WorktreeInventory(
      projectRoot: nil, taskWorktrees: [try task("active", activation: .active)])

    #expect(inventory.tabEmptyState(hasSelection: true, didCompleteInitialScan: true) == nil)
  }

  @Test("選べるタブがあれば、選択が無くても案内しない")
  func staysSilentWhileSelectableTabsExist() throws {
    let byTask = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        try task("active", activation: .active),
        try task("inactive", activation: .inactive),
      ])
    let byProjectRoot = WorktreeInventory(
      projectRoot: try root(), taskWorktrees: [try task("inactive", activation: .inactive)])

    #expect(byTask.tabEmptyState(hasSelection: false, didCompleteInitialScan: true) == nil)
    #expect(byProjectRoot.tabEmptyState(hasSelection: false, didCompleteInitialScan: true) == nil)
  }

  @Test("Active が到達可能でないだけのときは「到達できない」と案内する")
  func reportsNoReachableWorktrees() throws {
    let inventory = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        try task("unreachable", activation: .active, observation: .unreachable),
        try task("unobserved", activation: .active, observation: .observationFailed),
      ])

    #expect(
      inventory.tabEmptyState(hasSelection: false, didCompleteInitialScan: true)
        == .noReachableWorktrees)
  }

  @Test("Inactive しか無いときだけ Active 化を促す")
  func reportsNoActiveWorktrees() throws {
    let inventory = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        try task("inactive", activation: .inactive),
        try task("inactive-2", activation: .inactive, observation: .unreachable),
      ])

    #expect(
      inventory.tabEmptyState(hasSelection: false, didCompleteInitialScan: true)
        == .noActiveWorktrees)
  }

  @Test("選べる worktree の一覧は Active かつ到達可能に限る")
  func selectableExcludesInactiveAndUnreachable() throws {
    let inventory = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        try task("inactive", activation: .inactive),
        try task("unreachable", activation: .active, observation: .unreachable),
        try task("active", activation: .active),
      ])

    #expect(inventory.selectableTaskWorktrees.map(\.identity) == [try identity("active")])
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
