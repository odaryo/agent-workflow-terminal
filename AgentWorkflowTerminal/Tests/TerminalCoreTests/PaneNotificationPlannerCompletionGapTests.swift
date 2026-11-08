import Foundation
import TerminalCore
import Testing

@Suite("読めない回を挟む完了通知 (設計書 §11.2、#395 m3・残存3)")
struct PlannerCompletionGapTests: PaneNotificationPlannerTesting {
  let worktree: WorktreeIdentity
  let other: WorktreeIdentity

  init() throws {
    (worktree, other) = try Self.identities()
  }

  static let unreadableReasons: [PaneUserOptionUnreadableReason] = [
    .tooLong, .containsLineBreakOrUnitSeparator, .invalidUTF8, .malformedOutput,
  ]

  @Test("ps が読めない間の Working と完了 token を、回復後に1回通知する (m3)")
  func tokenWrittenWhileProcessIsUnobservableIsNotLost() {
    var planner = baselined([pane("%1", .completed)])
    var tracker = PaneTaskCompletionTracker()
    let token = AgentStampedValue(
      agentProcessID: 42, text: "done", turnStartedAt: Date(timeIntervalSince1970: 11))
    let previous = AgentStampedValue(
      agentProcessID: 42, text: "previous", turnStartedAt: Date(timeIntervalSince1970: 9))
    let oldReading = summary(.value("42 turn=9000 previous"), process: .unobservable)
    let raw = PaneUserOptionReading.value("42 turn=11000 done")
    let missing = summary(raw, process: .unobservable)
    let accepted = summary(raw, process: .identified(processID: 42))
    #expect(accepted == .accepted(token))
    #expect(PaneTaskCompletionTracker.isUndetermined(missing))

    let baseline = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: .accepted(previous), agentState: .completed,
      lastTurnEndObservedAt: Date(timeIntervalSince1970: 10))
    #expect(baseline == .completed(previous))
    #expect(deliver(&planner, baseline, reading: .accepted(previous)).isEmpty)
    let working = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: oldReading, agentState: .working,
      lastTurnEndObservedAt: Date(timeIntervalSince1970: 10))
    #expect(deliver(&planner, working, reading: oldReading).isEmpty)
    let written = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: missing, agentState: .working,
      lastTurnEndObservedAt: Date(timeIntervalSince1970: 12))
    #expect(deliver(&planner, written, reading: missing).isEmpty)
    let recovered = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: accepted, agentState: .working,
      lastTurnEndObservedAt: Date(timeIntervalSince1970: 12))
    #expect(recovered == .completed(token))
    #expect(
      deliver(&planner, recovered, reading: accepted)
        == [event("%1", .taskCompleted, completion: token)])
    let repeated = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: accepted, agentState: .completed,
      lastTurnEndObservedAt: Date(timeIntervalSince1970: 12))
    #expect(repeated == .completed(token))
    #expect(deliver(&planner, repeated, reading: accepted).isEmpty)
  }

  @Test("unreadable は完了の判定未確定である (残存3)", arguments: unreadableReasons)
  func unreadableIsUndetermined(reason: PaneUserOptionUnreadableReason) {
    #expect(PaneTaskCompletionTracker.isUndetermined(.discarded(.unreadable(reason))))
  }

  @Test(
    "unreadable の回は直前の完了表示・解除済み表示を保つ (残存3)",
    arguments: unreadableReasons, [false, true])
  func unreadableKeepsDisplay(reason: PaneUserOptionUnreadableReason, dismissed: Bool) {
    var tracker = PaneTaskCompletionTracker()
    let paneID = PaneID(rawValue: "%1")
    let completed = tracker.update(
      paneID: paneID, completion: .accepted(Self.first), agentState: .completed,
      lastTurnEndObservedAt: Date(timeIntervalSince1970: 100))
    #expect(completed == .completed(Self.first))
    let expected: PaneTaskCompletionDisplay = dismissed ? .dismissed(Self.first) : completed
    if dismissed {
      #expect(
        tracker.update(
          paneID: paneID, completion: .accepted(Self.first), agentState: .working) == expected)
    }
    #expect(
      tracker.update(
        paneID: paneID, completion: .discarded(.unreadable(reason)), agentState: .unknown)
        == expected)
    #expect(
      tracker.update(
        paneID: paneID, completion: .accepted(Self.first), agentState: .unknown) == expected)
  }

  @Test(
    "基準で unreadable だった pane は、次の読めた完了を静かに基準にする (残存3)",
    arguments: unreadableReasons)
  func unreadableDefersCompletionBaseline(reason: PaneUserOptionUnreadableReason) {
    var planner = baselined([pane("%1", .completed)])
    var tracker = PaneTaskCompletionTracker()
    let reading = PaneSummaryEntry<AgentStampedValue>.discarded(.unreadable(reason))
    let initial = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: reading, agentState: .completed)
    #expect(deliver(&planner, initial, reading: reading).isEmpty)
    let recovered = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: .accepted(Self.first), agentState: .completed)
    #expect(recovered == .completed(Self.first))
    #expect(deliver(&planner, recovered, reading: .accepted(Self.first)).isEmpty)
    #expect(deliver(&planner, recovered, reading: .accepted(Self.first)).isEmpty)
    let next = tracker.update(
      paneID: PaneID(rawValue: "%1"), completion: .accepted(Self.second), agentState: .completed)
    #expect(
      deliver(&planner, next, reading: .accepted(Self.second))
        == [event("%1", .taskCompleted, completion: Self.second)])
  }

  @Test(
    "完了通知の後に unreadable を挟んで同じ完了を読んでも通知は増えない (残存3)",
    arguments: unreadableReasons)
  func unreadableDoesNotRepeatCompletion(reason: PaneUserOptionUnreadableReason) {
    var planner = baselined([pane("%1", .completed)])
    var tracker = PaneTaskCompletionTracker()
    let paneID = PaneID(rawValue: "%1")
    let initial = tracker.update(paneID: paneID, completion: .unset, agentState: .completed)
    #expect(deliver(&planner, initial, reading: .unset).isEmpty)
    let completed = tracker.update(
      paneID: paneID, completion: .accepted(Self.first), agentState: .completed)
    #expect(
      deliver(&planner, completed, reading: .accepted(Self.first))
        == [event("%1", .taskCompleted, completion: Self.first)])
    let reading = PaneSummaryEntry<AgentStampedValue>.discarded(.unreadable(reason))
    let unreadable = tracker.update(paneID: paneID, completion: reading, agentState: .completed)
    #expect(deliver(&planner, unreadable, reading: reading).isEmpty)
    let recovered = tracker.update(
      paneID: paneID, completion: .accepted(Self.first), agentState: .completed)
    #expect(deliver(&planner, recovered, reading: .accepted(Self.first)).isEmpty)
  }

  private func deliver(
    _ planner: inout PaneNotificationPlanner, _ display: PaneTaskCompletionDisplay,
    reading: PaneSummaryEntry<AgentStampedValue>
  ) -> [PaneNotification] {
    completions(
      &planner, ["%1": display],
      undetermined: PaneTaskCompletionTracker.isUndetermined(reading) ? ["%1"] : [])
  }

  private func summary(
    _ completion: PaneUserOptionReading, process: PaneAgentProcess
  ) -> PaneSummaryEntry<AgentStampedValue> {
    PaneSummary(
      paneID: PaneID(rawValue: "%1"),
      readings: PaneSummaryReadings(
        status: .value(""), completion: completion, purpose: .value("")),
      agentProcess: process
    ).completion
  }
}
