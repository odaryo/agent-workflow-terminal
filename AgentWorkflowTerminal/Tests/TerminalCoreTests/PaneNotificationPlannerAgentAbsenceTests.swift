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

  @Test("C1: 移動先で先に届いた Agent 不在で記憶をリセットし、同じ Question を1回通知する")
  func absenceBeforeSessionAttachmentResetsAttentionMemory() throws {
    let start = Self.clock.now
    var planner = baselined([pane("%1", .working)], at: start)
    let question = complete([pane("%1", .question)])
    let notified = start.advanced(by: .seconds(1))
    try #require(
      planner.observeStates(question, in: worktree, at: notified) == [event("%1", .question)])

    planner.startObserving(other, at: notified)
    #expect(planner.observeStates(complete([]), in: other, at: notified).isEmpty)
    #expect(
      planner.observeStates(absent(), in: other, at: start.advanced(by: .seconds(2))).isEmpty)
    let attached = planner.observeCompletions(
      Self.keyed(["%1": .none]), undetermined: [], in: other,
      at: start.advanced(by: .seconds(3)))
    #expect(attached.isEmpty)

    let expected = PaneNotification.pane(
      PaneNotificationEvent(
        worktree: other, paneID: PaneID(rawValue: "%1"), kind: .question, completion: nil))
    #expect(
      planner.observeStates(question, in: other, at: start.advanced(by: .seconds(4)))
        == [expected])
    #expect(
      planner.observeStates(question, in: other, at: start.advanced(by: .seconds(5))).isEmpty)
  }

  @Test("S1: 猶予内に再開した基準の Agent 不在で記憶をリセットし、同じ Question を1回通知する")
  func absenceAtResumedBaselineResetsAttentionMemory() throws {
    let start = Self.clock.now
    var planner = baselined([pane("%1", .working)], at: start)
    let question = complete([pane("%1", .question)])
    try #require(
      planner.observeStates(question, in: worktree, at: start.advanced(by: .seconds(1)))
        == [event("%1", .question)])

    planner.stopObserving(worktree)
    let resumed = start.advanced(by: .seconds(2))
    planner.startObserving(worktree, at: resumed)
    #expect(planner.observeStates(absent(), in: worktree, at: resumed).isEmpty)
    #expect(
      planner.observeStates(question, in: worktree, at: start.advanced(by: .seconds(3)))
        == [event("%1", .question)])
    #expect(
      planner.observeStates(question, in: worktree, at: start.advanced(by: .seconds(4))).isEmpty)
  }

  @Test("#715: 再開後の未完の基準で Agent 不在を観測したら、再起動後の Question をまとめ通知に数える")
  func absenceBeforeCompleteResumedBaselineResetsAttentionMemory() throws {
    let start = Self.clock.now
    var planner = baselined([pane("%1", .working)], at: start)
    let question = complete([pane("%1", .question)])
    try #require(
      planner.observeStates(question, in: worktree, at: start.advanced(by: .seconds(1)))
        == [event("%1", .question)])

    planner.stopObserving(worktree)
    let resumed = start.advanced(by: .seconds(2))
    planner.startObserving(worktree, at: resumed)
    let incompleteAbsence = WorktreePaneAgentStates(
      panes: [], isComplete: false, agentAbsentPanes: [PaneID(rawValue: "%1")])
    #expect(planner.observeStates(incompleteAbsence, in: worktree, at: resumed).isEmpty)
    #expect(
      planner.observeStates(question, in: worktree, at: start.advanced(by: .seconds(3)))
        == [.attentionSummary(count: 1)])
    #expect(
      planner.observeStates(question, in: worktree, at: start.advanced(by: .seconds(4))).isEmpty)
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
