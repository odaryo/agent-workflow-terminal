import Foundation
import TerminalCore
import Testing

@Suite("Overview の未更新と未観測 (設計書 §13 / Issue #387)")
struct AgentPaneOverviewObservationTests {
  private let start = ContinuousClock().now

  @Test("pane は未更新か更新済みかや Needs Attention にかかわらず入力順を保つ")
  func panesKeepInputOrderRegardlessOfChangeTime() throws {
    let input = try task(
      "task",
      [
        pane("%1", .working), pane("%2", .idle, changedAt: start),
        pane("%3", .completed), pane("%4", .question),
        pane("%5", .permission, changedAt: start.advanced(by: .seconds(-100))),
        pane("%6", .error),
      ])

    let overview = try overview([input])

    #expect(
      overview.tasks.first?.rows.compactMap(\.pane).map(\.paneID.rawValue)
        == ["%1", "%2", "%3", "%4", "%5", "%6"])
  }

  @Test("Task は未更新か更新済みかや Needs Attention にかかわらず入力順を保つ")
  func tasksKeepInputOrderRegardlessOfChangeTime() throws {
    let first = try task("first", [pane("%1", .working)])
    let second = try task("second", [pane("%2", .idle)])
    let changed = try task("changed", [pane("%3", .working, changedAt: start)])
    let mixed = try task(
      "mixed",
      [pane("%4", .idle), pane("%5", .working, changedAt: start.advanced(by: .seconds(1)))])
    let attention = try task("attention", [pane("%6", .question)])
    let changedAttention = try task("changedAttention", [pane("%7", .error, changedAt: start)])

    let result = try overview([first, second, changed, mixed, attention, changedAttention])

    #expect(
      result.tasks.map(\.session)
        == [first, second, changed, mixed, attention, changedAttention].map(\.session))
  }

  // Adapter の結果の到着のばらつきは、App が最初に揃った観測まで安定化器へ渡さないことで吸収する。
  @Test("最初に揃った観測に在った pane は Overview で tmux 順と Task Tab 順を保つ")
  func adapterArrivalOrderDoesNotDetermineOverviewOrder() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    let states = stabilizer.observe([observedPane("%1"), observedPane("%2")], at: start)
    let combined = try task("combined", states)
    let first = try task("first", Array(states.prefix(1)))
    let second = try task("second", Array(states.suffix(1)))

    let result = try overview([second, first, combined])

    #expect(result.tasks.map(\.session) == [second, first, combined].map(\.session))
    #expect(result.tasks.last?.rows.compactMap(\.pane).map(\.paneID.rawValue) == ["%1", "%2"])
  }

  @Test(
    "基準観測の3 pane が Unknown から別々の時刻に Idle / Working へ決まっても tmux 順",
    arguments: [
      [AgentState.idle, .idle, .idle], [.working, .working, .working], [.idle, .working, .idle],
    ])
  func staggeredInitialResolutionKeepsTmuxOrder(_ destinations: [AgentState]) throws {
    var stabilizer = PaneDisplayStateStabilizer()
    let ids = ["%1", "%2", "%3"]
    var input = ids.map { observedPane($0, .unknown, unknownReason: .signalMissing) }
    var states = stabilizer.observe(input, at: start)
    #expect(states.map(\.changedAt) == [nil, nil, nil])

    for (step, index) in [2, 0, 1].enumerated() {
      let destination = destinations[index]
      input[index] = observedPane(ids[index], destination)
      let instant = start.advanced(by: .seconds((step + 1) * 20))
      states = stabilizer.observe(input, at: instant)
      if destination == .idle {
        let deadline = try #require(stabilizer.nextDeadline)
        #expect(deadline == instant.advanced(by: .seconds(9)))
        states = stabilizer.observe(input, at: deadline)
      }
      #expect(states[index].state == destination)
      #expect(states.map(\.changedAt) == [nil, nil, nil])
      let result = try overview([task("combined", states)])
      #expect(result.tasks.first?.rows.compactMap(\.pane).map(\.paneID.rawValue) == ids)
    }
    #expect(states.map(\.state) == destinations)
  }

  @Test(
    "判定不能の Unknown が1時間後に決まっても109秒で更新した pane との入力順を保つ",
    arguments: [AgentState.working, .question])
  func lateUndeterminedResolutionKeepsInputOrder(_ destination: AgentState) throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe(
      [observedPane("%1", .unknown, unknownReason: .adapterUndetermined), observedPane("%2")],
      at: start)
    let peerState: AgentState = destination == .working ? .completed : .question
    _ = stabilizer.observe(
      [
        observedPane("%1", .unknown, unknownReason: .adapterUndetermined),
        observedPane("%2", peerState),
      ], at: start.advanced(by: .seconds(109)))

    let resolvedAt = start.advanced(by: .seconds(3600))
    let states = stabilizer.observe(
      [observedPane("%1", destination), observedPane("%2", peerState)], at: resolvedAt)
    #expect(states.first { $0.paneID.rawValue == "%1" }?.changedAt == resolvedAt)
    #expect(
      states.first { $0.paneID.rawValue == "%2" }?.changedAt
        == start.advanced(by: .seconds(109)))
    let result = try overview([task("combined", Array(states.reversed()))])
    #expect(result.tasks.first?.rows.compactMap(\.pane).map(\.paneID.rawValue) == ["%2", "%1"])
  }

  @Test("未観測の Task は未観測の行1つで示し、Agent pane の有無によらず Task の入力順を保つ")
  func unobservedTasksHaveOwnRowAndKeepTabOrder() throws {
    let unseenA = try task("unseenA", [], isObserved: false)
    let emptyA = try task("emptyA", [])
    let active = try task("active", [pane("%1", .working)])
    let unseenB = try task("unseenB", [], isObserved: false)
    let emptyB = try task("emptyB", [])

    let result = try overview([unseenA, emptyA, active, unseenB, emptyB])

    #expect(
      result.tasks.map(\.session) == [unseenA, emptyA, active, unseenB, emptyB].map(\.session))
    #expect(
      result.tasks.filter { $0.session != active.session }.map(\.rows) == [
        [.notObserved], [.noAgentPane], [.notObserved], [.noAgentPane],
      ])
  }

  @Test("session 版と worktree 版の入力は未観測を保持し、Project Root も未観測の行1つにする")
  func unobservedProjectRootsKeepTheirOwnRows() throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let second = try #require(TerminalSessionKey(identity: identity, index: 2))
    let primary = OverviewWorktreeInput(worktree: identity, paneStates: [], isObserved: false)
    let extra = OverviewWorktreeInput(session: second, paneStates: [], isObserved: false)
    let input = OverviewProjectInput(
      project: identity, projectRootSessions: [primary, extra], tasks: [])

    let result = try #require(makeAgentPaneOverview([input]).first)

    #expect(!primary.isObserved)
    #expect(!extra.isObserved)
    #expect(result.projectRootSessions.map(\.session) == [primary.session, extra.session])
    #expect(result.projectRootSessions.map(\.rows) == [[.notObserved], [.notObserved]])
  }

  @Test("既定の入力は観測済みで、空配列を Agent pane なしとして扱う")
  func observationDefaultsToComplete() throws {
    let input = try task("empty", [])
    let sessionInput = OverviewWorktreeInput(session: input.session, paneStates: [])

    #expect(input.isObserved)
    #expect(sessionInput.isObserved)
    #expect(
      try overview([input, sessionInput]).tasks.map(\.rows) == [[.noAgentPane], [.noAgentPane]])
  }

  private func pane(
    _ id: String, _ state: AgentState, changedAt: ContinuousClock.Instant? = nil
  ) -> PaneDisplayState {
    PaneDisplayState(
      paneID: PaneID(rawValue: id), state: state, category: state.worktreeCategory,
      changedAt: changedAt)
  }

  private func observedPane(
    _ id: String, _ state: AgentState = .working,
    unknownReason: UnknownReason? = .adapterUndetermined
  ) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      observation: AgentStateObservation(
        state: state, adapterID: AgentAdapterID(rawValue: "test"), observedAt: .distantPast,
        unknownReason: state == .unknown ? unknownReason : nil))
  }

  private func task(
    _ name: String, _ panes: [PaneDisplayState], isObserved: Bool = true
  ) throws -> OverviewWorktreeInput {
    OverviewWorktreeInput(
      worktree: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/\(name)")),
      paneStates: panes, isObserved: isObserved)
  }

  private func overview(_ tasks: [OverviewWorktreeInput]) throws -> OverviewProject {
    let project = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    return try #require(
      makeAgentPaneOverview([
        OverviewProjectInput(project: project, projectRoot: nil, tasks: tasks)
      ]).first)
  }
}
