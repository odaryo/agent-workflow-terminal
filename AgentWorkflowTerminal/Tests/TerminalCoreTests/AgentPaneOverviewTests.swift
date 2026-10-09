import Foundation
import TerminalCore
import Testing

@Suite("全 Agent pane Overview の行と並び順 (設計書 §13)")
struct AgentPaneOverviewTests {
  private let base = ContinuousClock().now

  @Test("Project は入力 (登録) の順のまま並べ、Needs Attention があっても動かさない")
  func projectsKeepRegistrationOrder() throws {
    let quiet = try project(
      "/a/.git", tasks: [try task("/a/.git/worktrees/t", [pane("%1", .idle, 1)])])
    let urgent = try project(
      "/b/.git", tasks: [try task("/b/.git/worktrees/t", [pane("%2", .permission, 9)])])

    let overview = makeAgentPaneOverview([quiet, urgent])

    #expect(overview.map(\.project) == [quiet.project, urgent.project])
  }

  @Test("Project Root は Task と混ぜずに別枠へ置く")
  func projectRootIsSeparate() throws {
    let root = try task("/a", [pane("%9", .question, 9)])
    let input = try project(
      "/a/.git", root: root, tasks: [try task("/a/.git/worktrees/t", [pane("%1", .idle, 1)])])

    let overview = try #require(makeAgentPaneOverview([input]).first)

    #expect(overview.projectRoot?.worktree == root.worktree)
    #expect(overview.tasks.map(\.worktree) == [input.tasks[0].worktree])
  }

  @Test("Needs Attention の pane を含む Task を先に置き、残りは最終更新の新しい順")
  func tasksWithAttentionComeFirst() throws {
    let old = try task("/a/.git/worktrees/old", [pane("%1", .working, 1)])
    let recent = try task("/a/.git/worktrees/recent", [pane("%2", .working, 8)])
    let attention = try task(
      "/a/.git/worktrees/attention", [pane("%3", .working, 9), pane("%4", .error, 2)])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [old, recent, attention])]).first)

    #expect(overview.tasks.map(\.worktree) == [attention, recent, old].map(\.worktree))
  }

  @Test("Needs Attention の判定は大分類で行い、種別不明の注意状態も含める")
  func attentionIsDecidedByCategory() throws {
    let plain = try task("/a/.git/worktrees/plain", [pane("%1", .working, 9)])
    let undetermined = try task(
      "/a/.git/worktrees/undetermined",
      [
        PaneDisplayState(
          paneID: PaneID(rawValue: "%2"), state: .unknown, category: .needsAttention,
          changedAt: at(1))
      ])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [plain, undetermined])]).first)

    #expect(overview.tasks.map(\.worktree) == [undetermined, plain].map(\.worktree))
  }

  @Test("Needs Attention を含む Task どうしも最終更新の新しい順に並べる")
  func attentionTasksAreOrderedByLastUpdate() throws {
    let older = try task("/a/.git/worktrees/older", [pane("%1", .question, 2)])
    let newer = try task("/a/.git/worktrees/newer", [pane("%2", .idle, 7), pane("%3", .error, 1)])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [older, newer])]).first)

    #expect(overview.tasks.map(\.worktree) == [newer, older].map(\.worktree))
  }

  @Test("最終更新が同じ Task は入力 (tab) の順を保つ")
  func tiesKeepTabOrder() throws {
    let first = try task("/a/.git/worktrees/first", [pane("%1", .working, 5)])
    let second = try task("/a/.git/worktrees/second", [pane("%2", .idle, 5)])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [first, second])]).first)

    #expect(overview.tasks.map(\.worktree) == [first, second].map(\.worktree))
  }

  @Test("Agent pane の無い Task は Agent pane のある Task の後ろに tab 順で置く")
  func tasksWithoutAgentPanesComeLast() throws {
    let emptyA = try task("/a/.git/worktrees/emptyA", [])
    let busy = try task("/a/.git/worktrees/busy", [pane("%1", .idle, 1)])
    let emptyB = try task("/a/.git/worktrees/emptyB", [])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [emptyA, busy, emptyB])]).first)

    #expect(overview.tasks.map(\.worktree) == [busy, emptyA, emptyB].map(\.worktree))
  }

  @Test("Agent pane の無い Task と Project Root は「Agent pane なし」の行1つで示す")
  func emptyTaskHasSingleNoAgentRow() throws {
    let input = try project(
      "/a/.git", root: try task("/a", []), tasks: [try task("/a/.git/worktrees/empty", [])])

    let overview = try #require(makeAgentPaneOverview([input]).first)

    #expect(overview.projectRoot?.rows == [.noAgentPane])
    #expect(overview.tasks.first?.rows == [.noAgentPane])
  }

  @Test("Task 内は Needs Attention を先に、それぞれ最終更新の新しい順、同じなら入力順")
  func panesWithinTaskAreOrdered() throws {
    let input = try task(
      "/a/.git/worktrees/t",
      [
        pane("%1", .working, 3),
        pane("%2", .question, 1),
        pane("%3", .idle, 6),
        pane("%4", .permission, 4),
        pane("%5", .completed, 6),
      ])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    #expect(paneIDs(overview.tasks[0]) == ["%4", "%2", "%3", "%5", "%1"])
  }

  @Test("行にするのは状態のある (Agent と判定された) pane だけで、概要しか無い pane は出さない")
  func onlyAgentPanesBecomeRows() throws {
    var input = try task("/a/.git/worktrees/t", [pane("%1", .working, 1)])
    input.details = [
      PaneID(rawValue: "%1"): OverviewPaneDetail(purpose: "実装"),
      PaneID(rawValue: "%7"): OverviewPaneDetail(purpose: "zsh の pane"),
    ]

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    #expect(paneIDs(overview.tasks[0]) == ["%1"])
  }

  @Test("概要と位置を行へ渡し、概要がまだ無い pane は空の概要になる")
  func detailsArePassedThrough() throws {
    let detail = OverviewPaneDetail(
      location: PaneLocation(windowIndex: 1, paneIndex: 2), purpose: "目的", status: "実装中",
      isTaskCompleted: true)
    var input = try task("/a/.git/worktrees/t", [pane("%1", .working, 2), pane("%2", .idle, 1)])
    input.details = [PaneID(rawValue: "%1"): detail]

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    let panes = overview.tasks[0].rows.compactMap(\.pane)
    #expect(panes.first?.detail == detail)
    #expect(panes.last?.detail == OverviewPaneDetail())
  }

  @Test("メイン pane に登録された pane だけに印を付ける")
  func marksRegisteredMainPane() throws {
    var input = try task("/a/.git/worktrees/t", [pane("%1", .working, 2), pane("%2", .idle, 1)])
    input.mainPane = PaneID(rawValue: "%2")

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    let panes = overview.tasks[0].rows.compactMap(\.pane)
    #expect(panes.map(\.isMain) == [false, true])
  }

  private func at(_ seconds: Int) -> ContinuousClock.Instant {
    base.advanced(by: .seconds(seconds))
  }

  private func pane(_ id: String, _ state: AgentState, _ seconds: Int) -> PaneDisplayState {
    PaneDisplayState(
      paneID: PaneID(rawValue: id), state: state, category: state.worktreeCategory,
      changedAt: at(seconds))
  }

  private func task(_ path: String, _ panes: [PaneDisplayState]) throws -> OverviewWorktreeInput {
    OverviewWorktreeInput(
      worktree: try #require(WorktreeIdentity(rawValue: path)), paneStates: panes)
  }

  private func project(
    _ path: String, root: OverviewWorktreeInput? = nil, tasks: [OverviewWorktreeInput]
  ) throws -> OverviewProjectInput {
    OverviewProjectInput(
      project: try #require(WorktreeIdentity(rawValue: path)), projectRoot: root, tasks: tasks)
  }

  private func paneIDs(_ worktree: OverviewWorktree) -> [String] {
    worktree.rows.compactMap(\.pane).map(\.paneID.rawValue)
  }
}
