import TerminalCore
import Testing

@Suite("解除判定時の完了 token の読み直し (Issue #386)")
struct PaneTaskCompletionFreshReadTests {
  private static let pane = PaneID(rawValue: "%1")
  private static let first = AgentStampedValue(agentProcessID: 42, text: "t1")
  private static let second = AgentStampedValue(agentProcessID: 42, text: "t2")

  @Test(
    "古い unset で解除の遷移を観測しても、読み直した token は次の refresh で復活しない",
    arguments: [AgentState.idle, .completed])
  func dismissesTokenReadAtTransition(turnEnd: AgentState) {
    var tracker = PaneTaskCompletionTracker()
    #expect(tracker.update(paneID: Self.pane, completion: .unset, agentState: .working) == .none)
    #expect(tracker.update(paneID: Self.pane, completion: .unset, agentState: turnEnd) == .none)
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(tracker.update(paneID: Self.pane, completion: .unset, agentState: .working) == .none)
    #expect(tracker.needsFreshCompletion(paneID: Self.pane))

    #expect(
      tracker.resolveDismissal(paneID: Self.pane, freshCompletion: .accepted(Self.first))
        == .dismissed(Self.first))
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
  }

  @Test("読み直した値が unset なら、次のターンの Working 中に書かれた token は完了になる")
  func showsTokenWrittenAfterFreshUnset() {
    var tracker = PaneTaskCompletionTracker()
    #expect(tracker.update(paneID: Self.pane, completion: .unset, agentState: .working) == .none)
    #expect(tracker.update(paneID: Self.pane, completion: .unset, agentState: .completed) == .none)
    #expect(tracker.update(paneID: Self.pane, completion: .unset, agentState: .working) == .none)
    #expect(tracker.needsFreshCompletion(paneID: Self.pane))

    #expect(tracker.resolveDismissal(paneID: Self.pane, freshCompletion: .unset) == .none)
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.second), agentState: .working)
        == .completed(Self.second))
  }

  @Test(
    "読み直しで Agent プロセスが判定できなければ、仮の解除値を保って読み直し待ちを解く",
    arguments: [PaneSummaryEntry<AgentStampedValue>.unset, .accepted(first)])
  func undeterminedFreshCompletionKeepsProvisionalDismissal(
    stale: PaneSummaryEntry<AgentStampedValue>
  ) {
    var tracker = PaneTaskCompletionTracker()
    let provisional = stale.value.map { PaneTaskCompletionDisplay.dismissed($0) } ?? .none
    _ = tracker.update(paneID: Self.pane, completion: stale, agentState: .working)
    _ = tracker.update(paneID: Self.pane, completion: stale, agentState: .completed)
    #expect(
      tracker.update(paneID: Self.pane, completion: stale, agentState: .working) == provisional)
    #expect(tracker.needsFreshCompletion(paneID: Self.pane))

    #expect(
      tracker.resolveDismissal(
        paneID: Self.pane,
        freshCompletion: .discarded(.agentProcessUnobservable(written: 42)))
        == provisional)
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.update(paneID: Self.pane, completion: stale, agentState: .working) == provisional)
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.second), agentState: .working)
        == .completed(Self.second))
  }

  @Test("読み直し待ち中の update は仮の解除値を保ち、resolveDismissal だけが解除を確定する")
  func updatesWhilePendingKeepProvisionalDismissal() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
    #expect(tracker.needsFreshCompletion(paneID: Self.pane))

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.second), agentState: .working)
        == .completed(Self.second))
    #expect(tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
    #expect(tracker.needsFreshCompletion(paneID: Self.pane))

    #expect(
      tracker.resolveDismissal(paneID: Self.pane, freshCompletion: .accepted(Self.second))
        == .dismissed(Self.second))
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.resolveDismissal(paneID: Self.pane, freshCompletion: .accepted(Self.first))
        == .dismissed(Self.second))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
  }

  @Test(
    "解除の遷移がなければ読み直しは不要で、resolveDismissal は現在の表示と記憶を変えない",
    arguments: [AgentState.working, .question, .permission, .error, .unknown, nil])
  func resolutionWithoutTransitionDoesNothing(previous: AgentState?) {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: previous)
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.resolveDismissal(paneID: Self.pane, freshCompletion: .accepted(Self.second))
        == .completed(Self.first))
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.second), agentState: .working)
        == .completed(Self.second))
  }

  @Test("forget は読み直し待ちも消し、その後の resolveDismissal は表示を復元しない")
  func forgetDropsPendingDismissal() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
    #expect(tracker.needsFreshCompletion(paneID: Self.pane))

    tracker.forget(paneID: Self.pane)

    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.resolveDismissal(paneID: Self.pane, freshCompletion: .accepted(Self.first)) == .none)
    #expect(!tracker.needsFreshCompletion(paneID: Self.pane))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
  }
}
