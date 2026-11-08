import Foundation
import TerminalCore
import Testing

@Suite("毎回の応答終了観測による完了解除 (設計書 §12.7 / Issue #386)")
struct CompletionLastTurnEndTests {
  private let pane = PaneID(rawValue: "%1")

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private func value(_ seconds: TimeInterval?) -> AgentStampedValue {
    AgentStampedValue(agentProcessID: 42, text: "done", turnStartedAt: seconds.map(date))
  }

  @Test("短い次ターンの完了を、Working 自身が運んだ最新の応答終了時刻で解除する (M1)")
  func workingCarriesLatestTurnEnd() {
    var tracker = PaneTaskCompletionTracker()
    let next = value(11)
    _ = tracker.update(
      paneID: pane, completion: .unset, agentState: .completed, lastTurnEndObservedAt: date(10))
    #expect(
      tracker.update(
        paneID: pane, completion: .accepted(next), agentState: .completed,
        lastTurnEndObservedAt: date(10)) == .completed(next))
    #expect(
      tracker.update(
        paneID: pane, completion: .accepted(next), agentState: .working,
        lastTurnEndObservedAt: date(16)) == .dismissed(next))
  }

  @Test("Unknown が運んだ時刻を記憶し、直前の既知の Completed から Working へ解除する")
  func unknownCarriesTimeWithoutReplacingKnownState() {
    var tracker = PaneTaskCompletionTracker()
    let next = value(11)
    _ = tracker.update(
      paneID: pane, completion: .unset, agentState: .completed, lastTurnEndObservedAt: date(10))
    #expect(
      tracker.update(
        paneID: pane, completion: .accepted(next), agentState: .unknown,
        lastTurnEndObservedAt: date(16)) == .completed(next))
    #expect(
      tracker.update(
        paneID: pane, completion: .accepted(next), agentState: .working,
        lastTurnEndObservedAt: date(16)) == .dismissed(next))
  }

  @Test(
    "state によらず時刻を記憶し、後の nil・過去の時刻で tL を戻さない",
    arguments: [
      AgentState.working, .unknown, .question, .permission, .error, .idle, .completed, nil,
    ],
    [TimeInterval(10), nil])
  func carriedTimeNeverMovesBackward(state: AgentState?, later: TimeInterval?) {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(
      paneID: pane, completion: .unset, agentState: state, lastTurnEndObservedAt: date(16))
    _ = tracker.update(
      paneID: pane, completion: .unset, agentState: .completed,
      lastTurnEndObservedAt: later.map(date))
    #expect(
      tracker.update(paneID: pane, completion: .accepted(value(11)), agentState: .working)
        == .dismissed(value(11)))
    #expect(
      tracker.update(paneID: pane, completion: .accepted(value(17)), agentState: .working)
        == .completed(value(17)))
  }

  @Test("閾値はミリ秒へ切り捨て、同じミリ秒の開始は残し、前のミリ秒は解除する (m2)", arguments: [true, false])
  func thresholdUsesMilliseconds(sameMillisecond: Bool) {
    var tracker = PaneTaskCompletionTracker()
    let completion = value(sameMillisecond ? 1_794_130_451.048 : 1_794_130_451.047)
    _ = tracker.update(
      paneID: pane, completion: .unset, agentState: .completed,
      lastTurnEndObservedAt: date(1_794_130_451.0485))
    #expect(
      tracker.update(paneID: pane, completion: .accepted(completion), agentState: .working)
        == (sameMillisecond ? .completed(completion) : .dismissed(completion)))
  }

  @Test("解除閾値があっても開始時刻 nil の完了は解除しない (m1)")
  func missingTurnStartKeepsCompletion() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(
      paneID: pane, completion: .unset, agentState: .completed, lastTurnEndObservedAt: date(16))
    _ = tracker.update(paneID: pane, completion: .unset, agentState: .working)
    #expect(
      tracker.update(paneID: pane, completion: .accepted(value(11)), agentState: .working)
        == .dismissed(value(11)))
    #expect(
      tracker.update(paneID: pane, completion: .accepted(value(nil)), agentState: .working)
        == .completed(value(nil)))
  }
}
