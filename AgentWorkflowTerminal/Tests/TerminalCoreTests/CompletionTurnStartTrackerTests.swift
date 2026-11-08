import Foundation
import TerminalCore
import Testing

@Suite("ターン開始時刻による完了解除 (設計書 §12.7 / Issue #386)")
struct CompletionTurnStartTrackerTests {
  private static let pane = PaneID(rawValue: "%1")
  private static let undetermined: [PaneSummaryEntry<AgentStampedValue>] = [
    .discarded(.agentProcessUnobservable(written: 42)),
    .discarded(.agentProcessAmbiguous(written: 42, candidates: [42, 43])),
  ]

  private func value(_ start: TimeInterval, token: String = "same") -> AgentStampedValue {
    AgentStampedValue(agentProcessID: 42, text: token, turnStartedAt: date(start))
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private func observe(
    _ tracker: inout CompletionObservationFixture,
    _ completion: PaneSummaryEntry<AgentStampedValue>,
    _ state: AgentState?, at seconds: TimeInterval?
  ) -> PaneTaskCompletionDisplay {
    tracker.update(
      paneID: Self.pane, completion: completion, agentState: state,
      observedAt: seconds.map { date($0) })
  }

  @Test("Completed → Working の後で初めて届いた旧ターンの token は解除済み")
  func lateOldTokenIsDismissed() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .completed, at: 100)
    _ = observe(&tracker, .unset, .working, at: 120)
    #expect(observe(&tracker, .accepted(value(90)), .working, at: nil) == .dismissed(value(90)))
    #expect(
      observe(&tracker, .accepted(value(95, token: "changed")), .working, at: nil)
        == .dismissed(value(95, token: "changed")))
  }

  @Test(
    "次ターンの token は最初の Working 観測より先に届いても取りこぼさない",
    arguments: [true, false])
  func shortNextTurnRemainsCompleted(arrivesWithWorking: Bool) {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .accepted(value(90)), .completed, at: 100)
    let reading: PaneSummaryEntry<AgentStampedValue> =
      arrivesWithWorking ? .accepted(value(110)) : .unset
    let display = observe(&tracker, reading, .working, at: 120)
    if arrivesWithWorking { #expect(display == .completed(value(110))) }
    #expect(observe(&tracker, .accepted(value(110)), .working, at: nil) == .completed(value(110)))
  }

  @Test("開始時刻が解除閾値と等しい場合は完了を残す")
  func equalityKeepsCompletion() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .idle, at: 100)
    #expect(observe(&tracker, .accepted(value(100)), .working, at: 120) == .completed(value(100)))
  }

  @Test("応答終了を繰り返し観測したら最新の時刻まで解除閾値を進める")
  func latestTurnEndObservationIsUsed() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .completed, at: 100)
    _ = observe(&tracker, .unset, .idle, at: 120)
    _ = observe(&tracker, .unset, .working, at: 140)
    #expect(observe(&tracker, .accepted(value(110)), .working, at: nil) == .dismissed(value(110)))
  }

  @Test("応答終了の観測時刻が過去へ戻っても最新時刻を巻き戻さない")
  func turnEndTimeNeverMovesBackward() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .idle, at: 120)
    _ = observe(&tracker, .unset, .completed, at: 100)
    _ = observe(&tracker, .unset, .working, at: 90)
    #expect(observe(&tracker, .accepted(value(110)), .working, at: nil) == .dismissed(value(110)))
  }

  @Test("次の解除遷移の時刻が過去へ戻っても解除閾値は前進のみ")
  func dismissalThresholdNeverMovesBackward() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .completed, at: 120)
    _ = observe(&tracker, .unset, .working, at: 130)
    _ = observe(&tracker, .unset, .idle, at: 80)
    _ = observe(&tracker, .unset, .working, at: 90)
    #expect(observe(&tracker, .accepted(value(110)), .working, at: nil) == .dismissed(value(110)))
  }

  @Test("Unknown は応答終了の時刻と直前の既知の状態を変えない")
  func unknownPreservesStateAndTime() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .completed, at: 100)
    _ = observe(&tracker, .unset, .unknown, at: 130)
    _ = observe(&tracker, .unset, .working, at: 140)
    #expect(observe(&tracker, .accepted(value(90)), .working, at: nil) == .dismissed(value(90)))
    #expect(observe(&tracker, .accepted(value(110)), .working, at: nil) == .completed(value(110)))
  }

  @Test("解除遷移が無ければ、後の応答終了を観測しても完了は解除しない")
  func endingObservationAloneDoesNotDismiss() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .working, at: 100)
    #expect(observe(&tracker, .accepted(value(90)), .working, at: 120) == .completed(value(90)))
    #expect(observe(&tracker, .accepted(value(90)), .completed, at: 140) == .completed(value(90)))
  }

  @Test("スクロール中など応答終了を観測しないまま Working が続けば前ターンの完了は残る")
  func missingTurnEndKeepsPreviousCompletion() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .accepted(value(90)), .working, at: 100)
    _ = observe(&tracker, .accepted(value(90)), .unknown, at: 120)
    #expect(observe(&tracker, .accepted(value(90)), .working, at: 140) == .completed(value(90)))
  }

  @Test(
    "プロセス未特定でも解除遷移を消費し、次の既知の状態に関係なく旧ターンを解除する (#395 m3)",
    arguments: undetermined)
  func undeterminedWorkingAdvancesThreshold(reading: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .accepted(value(90)), .completed, at: 100)
    #expect(observe(&tracker, reading, .working, at: 120) == .completed(value(90)))
    #expect(observe(&tracker, .accepted(value(95)), .completed, at: 140) == .dismissed(value(95)))
    #expect(observe(&tracker, .accepted(value(110)), .completed, at: nil) == .completed(value(110)))
  }

  @Test("プロセス未特定でも応答終了の時刻と状態を記憶する", arguments: undetermined)
  func undeterminedTurnEndIsRemembered(reading: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .accepted(value(90)), .working, at: 100)
    #expect(observe(&tracker, reading, .completed, at: 120) == .completed(value(90)))
    _ = observe(&tracker, .unset, .working, at: 140)
    #expect(observe(&tracker, .accepted(value(110)), .working, at: nil) == .dismissed(value(110)))
  }

  @Test("プロセス未特定の Question も既知の状態として進める", arguments: undetermined)
  func undeterminedInTurnStateIsRemembered(reading: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .accepted(value(90)), .completed, at: 100)
    #expect(observe(&tracker, reading, .question, at: 120) == .completed(value(90)))
    #expect(observe(&tracker, .accepted(value(90)), .working, at: 140) == .completed(value(90)))
  }

  @Test("観測時刻が nil の応答終了は以前の tL を進めない")
  func summaryReadDoesNotAdvanceTurnEndTime() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .completed, at: 100)
    _ = observe(&tracker, .unset, .idle, at: nil)
    _ = observe(&tracker, .unset, .working, at: 140)
    #expect(observe(&tracker, .accepted(value(110)), .working, at: nil) == .completed(value(110)))
    #expect(observe(&tracker, .accepted(value(90)), .working, at: nil) == .dismissed(value(90)))
  }

  @Test("観測時刻が一度も無ければ応答終了から Working へ移っても解除閾値を作らない")
  func missingObservationTimeDoesNotInventThreshold() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(value(90)), agentState: .completed)
    #expect(
      observe(&tracker, .accepted(value(90)), .working, at: 140) == .completed(value(90)))
  }

  @Test("同じ token でも開始時刻が違えば dismissed の値を区別できる")
  func dismissedValuesDistinguishTurnStart() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .completed, at: 100)
    _ = observe(&tracker, .unset, .working, at: 120)
    let first = observe(&tracker, .accepted(value(80)), .working, at: nil)
    let second = observe(&tracker, .accepted(value(90)), .working, at: nil)
    #expect(first == .dismissed(value(80)))
    #expect(second == .dismissed(value(90)))
    #expect(first != second)
  }

  @Test("forget は解除閾値を消し、再起動相当では Working でも有効な完了を受理する")
  func forgetResetsThreshold() {
    var tracker = CompletionObservationFixture()
    _ = observe(&tracker, .unset, .completed, at: 100)
    _ = observe(&tracker, .unset, .working, at: 120)
    #expect(observe(&tracker, .accepted(value(90)), .working, at: nil) == .dismissed(value(90)))
    tracker.forget(paneID: Self.pane)
    #expect(observe(&tracker, .accepted(value(90)), .working, at: 140) == .completed(value(90)))
  }
}
