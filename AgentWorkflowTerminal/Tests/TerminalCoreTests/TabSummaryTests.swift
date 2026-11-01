import TerminalCore
import Testing

@Suite("タブの右クリック一覧の順序と行 (設計書 §5.3 / §13)")
struct TabSummaryTests {
  private let base = ContinuousClock().now

  @Test("タブが無ければ一覧も空になる")
  func noTabsYieldsNoSummaries() {
    #expect(makeTabSummaries([]).isEmpty)
  }

  @Test("Idle、Question、Agent pane なしのタブを、同じディレクトリでも入力順に保つ")
  func tabsKeepInputOrder() throws {
    let tabs = [
      try tab(1, [pane("%1", .idle, 1)]),
      try tab(2, [pane("%2", .question, 2)]),
      try tab(3, []),
    ]

    let summaries = makeTabSummaries(tabs)

    #expect(summaries.map(\.session) == tabs.map(\.session))
  }

  @Test("Agent pane が無ければ、行は Agent pane なしの1行になる")
  func noAgentPaneHasPlaceholder() throws {
    var input = try tab(1, [])
    input.details = [PaneID(rawValue: "%9"): OverviewPaneDetail(purpose: "shell")]

    let summary = try #require(makeTabSummaries([input]).first)

    #expect(summary.rows == [.noAgentPane])
  }

  @Test("pane 行は Overview と一致し、Needs Attention を先に各群で新しい順に並べる")
  func rowsMatchOverviewOrder() throws {
    let input = try tab(
      2,
      [
        pane("%1", .working, 3),
        pane("%2", .question, 1),
        pane("%3", .idle, 6),
        pane("%4", .permission, 4),
        pane("%5", .completed, 6),
      ])
    let project = OverviewProjectInput(
      project: try #require(WorktreeIdentity(rawValue: "/a/.git")),
      projectRootSessions: [input], tasks: [])

    let summary = try #require(makeTabSummaries([input]).first)
    let overview = try #require(makeAgentPaneOverview([project]).first)
    let root = try #require(overview.projectRootSessions.first)

    #expect(summary.rows == root.rows)
    #expect(
      summary.rows.compactMap(\.pane).map(\.paneID.rawValue)
        == ["%4", "%2", "%3", "%5", "%1"])
  }

  @Test("pane 行に表示状態、対応する details または既定値、mainPane の印を渡す")
  func rowsCarryDetailsAndMainPane() throws {
    let working = pane("%1", .working, 2)
    let idle = pane("%2", .idle, 1)
    let detail = OverviewPaneDetail(
      location: PaneLocation(windowIndex: 1, paneIndex: 2), purpose: "目的", status: "実装中",
      isTaskCompleted: true)
    var input = try tab(1, [idle, working])
    input.details = [
      working.paneID: detail,
      PaneID(rawValue: "%9"): OverviewPaneDetail(purpose: "非 Agent pane"),
    ]
    input.mainPane = idle.paneID

    let summary = try #require(makeTabSummaries([input]).first)
    let panes = summary.rows.compactMap(\.pane)

    #expect(summary.rows.count == 2)
    #expect(panes.map(\.display) == [working, idle])
    #expect(panes.map(\.detail) == [detail, OverviewPaneDetail()])
    #expect(panes.map(\.isMain) == [false, true])
  }

  private func pane(_ id: String, _ state: AgentState, _ seconds: Int) -> PaneDisplayState {
    PaneDisplayState(
      paneID: PaneID(rawValue: id), state: state, category: state.worktreeCategory,
      changedAt: base.advanced(by: .seconds(seconds)))
  }

  private func tab(_ index: Int, _ panes: [PaneDisplayState]) throws -> OverviewWorktreeInput {
    let identity = try #require(WorktreeIdentity(rawValue: "/a"))
    let session = try #require(TerminalSessionKey(identity: identity, index: index))
    return OverviewWorktreeInput(session: session, paneStates: panes)
  }
}
