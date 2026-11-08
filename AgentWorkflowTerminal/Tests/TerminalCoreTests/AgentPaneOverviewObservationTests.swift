import TerminalCore
import Testing

@Suite("Overview の未更新と未観測 (設計書 §13 / Issue #387)")
struct AgentPaneOverviewObservationTests {
  private let start = ContinuousClock().now

  @Test("未更新の pane はどの更新時刻より古く、同じ群の未更新どうしは tmux 順になる")
  func unchangedPanesSortAfterChangedPanes() throws {
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
        == ["%5", "%4", "%6", "%2", "%1", "%3"])
  }

  @Test("未更新の Task は更新済み Task より古く、未更新どうしは Task Tab 順になる")
  func unchangedTasksSortAfterChangedTasks() throws {
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
        == [changedAttention, attention, mixed, changed, first, second].map(\.session))
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

  @Test("未観測の Task は未観測の行1つで、pane の無い Task と同じ群に Task Tab 順で置く")
  func unobservedTasksHaveOwnRowAndKeepTabOrder() throws {
    let unseenA = try task("unseenA", [], isObserved: false)
    let emptyA = try task("emptyA", [])
    let active = try task("active", [pane("%1", .working)])
    let unseenB = try task("unseenB", [], isObserved: false)
    let emptyB = try task("emptyB", [])

    let result = try overview([unseenA, emptyA, active, unseenB, emptyB])

    #expect(
      result.tasks.map(\.session) == [active, unseenA, emptyA, unseenB, emptyB].map(\.session))
    #expect(
      result.tasks.map(\.rows).dropFirst() == [
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

  private func observedPane(_ id: String) -> PaneAgentState {
    PaneAgentState(id: PaneID(rawValue: id), state: .working, lastUpdatedAt: .distantPast)
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
