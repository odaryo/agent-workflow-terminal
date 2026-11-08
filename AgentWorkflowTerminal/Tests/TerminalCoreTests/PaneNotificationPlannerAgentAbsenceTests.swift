import TerminalCore
import Testing

@Suite("Agent 終了と判断待ち通知 (設計書 §11.2、#395 m2)")
struct PaneNotificationPlannerAgentAbsenceTests: PaneNotificationPlannerTesting {
  let worktree: WorktreeIdentity
  let other: WorktreeIdentity

  init() throws {
    (worktree, other) = try Self.identities()
  }

  @Test(
    "Agent 終了を挟んだ同じ判断待ちは新しい遷移として1回通知する",
    arguments: [PaneNotificationKind.question, .permission, .attentionUnspecified])
  func restartedAgentGetsNewAttention(kind: PaneNotificationKind) {
    var planner = baselined([pane("%1", .working)])
    let attention = attentionPane(kind)
    #expect(observe(&planner, [attention]) == [event("%1", kind)])
    #expect(planner.observeStates(absent(), in: worktree, at: Self.clock.now).isEmpty)
    #expect(observe(&planner, [attention]) == [event("%1", kind)])
    #expect(observe(&planner, [attention]).isEmpty)
  }

  @Test("Agent 終了の情報がない pane 消失では同じ Question を再通知しない")
  func missingPaneKeepsAttentionMemory() {
    var planner = baselined([pane("%1", .working)])
    #expect(observe(&planner, [pane("%1", .question)]) == [event("%1", .question)])
    #expect(observe(&planner, []).isEmpty)
    #expect(observe(&planner, [pane("%1", .question)]).isEmpty)
  }

  @Test("基準の Agent 不在そのものでは通知せず、後の Question は1回通知する")
  func absenceAtBaselineIsSilent() {
    var planner = started()
    #expect(planner.observeStates(absent(), in: worktree, at: Self.clock.now).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: Self.clock.now).isEmpty)
    #expect(observe(&planner, [pane("%1", .question)]) == [event("%1", .question)])
    #expect(observe(&planner, [pane("%1", .question)]).isEmpty)
  }

  @Test("基準で判断待ちだった Agent が終了したら、pane が残ってもまとめ通知に数えない")
  func summaryExcludesExitedAgent() {
    var planner = started()
    #expect(observe(&planner, [pane("%1", .question), pane("%2", .permission)]).isEmpty)
    #expect(completions(&planner, ["%1": .none, "%2": .none]).isEmpty)
    let snapshot = WorktreePaneAgentStates(
      panes: [pane("%2", .permission)], isComplete: true,
      agentAbsentPanes: [PaneID(rawValue: "%1")])
    #expect(planner.observeStates(snapshot, in: worktree, at: Self.clock.now).isEmpty)
    #expect(
      planner.setSummaryGate(isOpen: true, at: Self.clock.now) == [.attentionSummary(count: 1)])
    #expect(
      observe(&planner, [pane("%1", .question), pane("%2", .permission)])
        == [event("%1", .question)])
  }

  private func absent() -> WorktreePaneAgentStates {
    WorktreePaneAgentStates(
      panes: [], isComplete: true, agentAbsentPanes: [PaneID(rawValue: "%1")])
  }

  private func attentionPane(_ kind: PaneNotificationKind) -> PaneAgentState {
    switch kind {
    case .question: pane("%1", .question)
    case .permission: pane("%1", .permission)
    default: attentionUnknown("%1")
    }
  }
}
