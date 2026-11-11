import TerminalCore
import Testing

@Suite("引き渡し済みの印の記録と解除 (設計書 §3.1、§13、Issue #828)")
struct PaneHandoffTrackerTests {
  private static let pane = PaneID(rawValue: "%22")
  private static let other = PaneID(rawValue: "%23")

  @Test("記録の直後と、記録したターンの Working が続く間は引き渡し済みのまま")
  func keepsRecordDuringRecordingTurn() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    #expect(tracker.isHandedOff(paneID: Self.pane))
    let kept = Self.observe(&tracker, [.working, .working])
    #expect(kept == [true, true])
    #expect(tracker.isHandedOff(paneID: Self.pane))
  }

  @Test(
    "記録の後に応答終了を観測してから Working に入ったら記録を消す",
    arguments: [AgentState.completed, .idle])
  func clearsOnWorkingAfterTurnEnd(turnEnd: AgentState) {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    let beforeWorking = Self.observe(&tracker, [.working, turnEnd])
    #expect(beforeWorking == [true, true])
    #expect(tracker.isHandedOff(paneID: Self.pane))

    let cleared = Self.observe(&tracker, [.working])
    #expect(cleared == [false])
    #expect(!tracker.isHandedOff(paneID: Self.pane))
    // 消えた後は、再び応答終了を経ても記録は戻らない。
    let afterClear = Self.observe(&tracker, [.completed, .working])
    #expect(afterClear == [false, false])
    #expect(!tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("Unknown と観測なしは直前の応答終了を保ち、その後の Working で記録を消す")
  func unknownAndNilKeepPreviousTurnEnd() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    let beforeWorking = Self.observe(&tracker, [.completed, .unknown, nil])
    #expect(beforeWorking == [true, true, true])
    #expect(tracker.isHandedOff(paneID: Self.pane))

    let cleared = Self.observe(&tracker, [.working])
    #expect(cleared == [false])
    #expect(!tracker.isHandedOff(paneID: Self.pane))
  }

  @Test(
    "応答終了でない既知の状態の直後の Working では記録を消さない",
    arguments: [AgentState.question, .permission, .error])
  func keepsRecordOnWorkingAfterNonTurnEnd(state: AgentState) {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    let kept = Self.observe(&tracker, [state, .working])
    #expect(kept == [true, true])
    #expect(tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("応答終了の後に Question を観測したら、その後の Working では記録を消さない")
  func questionOverridesPreviousTurnEnd() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    let kept = Self.observe(&tracker, [.completed, .question, .working])
    #expect(kept == [true, true, true])
    #expect(tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("記録より前に観測した応答終了は引き継がず、記録の直後の Working では消さない")
  func ignoresStatesObservedBeforeRecord() {
    var tracker = PaneHandoffTracker()
    let beforeRecord = Self.observe(&tracker, [.completed])
    #expect(beforeRecord == [false])
    tracker.record(paneID: Self.pane, processID: 100)
    let kept = Self.observe(&tracker, [.working])
    #expect(kept == [true])
    #expect(tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("記録の無い pane は応答終了から Working を経ても記録されない")
  func unrecordedPaneStaysUnrecorded() {
    var tracker = PaneHandoffTracker()
    let results = Self.observe(&tracker, [.working, .completed, .working])
    #expect(results == [false, false, false])
    #expect(!tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("記録をやり直すと、それまでに観測した応答終了を忘れる")
  func rerecordForgetsPreviousTurnEnd() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    let first = Self.observe(&tracker, [.completed])
    #expect(first == [true])
    tracker.record(paneID: Self.pane, processID: 100)
    let kept = Self.observe(&tracker, [.working])
    #expect(kept == [true])
    #expect(tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("記録した pane_pid と同じ pid を観測しても記録は残る")
  func keepsRecordForSameProcess() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    tracker.paneProcessObserved(paneID: Self.pane, processID: 100)
    #expect(tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("記録した pane_pid と違う pid を観測したら記録を消す")
  func clearsRecordForDifferentProcess() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    #expect(tracker.isHandedOff(paneID: Self.pane))
    tracker.paneProcessObserved(paneID: Self.pane, processID: 200)
    #expect(!tracker.isHandedOff(paneID: Self.pane))
    let afterClear = Self.observe(&tracker, [.working])
    #expect(afterClear == [false])
  }

  @Test("記録時の pane_pid が不明なら最初に観測した pid を採り、次に違う pid が来たら記録を消す")
  func adoptsFirstObservedProcess() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: nil)
    #expect(tracker.isHandedOff(paneID: Self.pane))
    tracker.paneProcessObserved(paneID: Self.pane, processID: 100)
    #expect(tracker.isHandedOff(paneID: Self.pane))
    tracker.paneProcessObserved(paneID: Self.pane, processID: 100)
    #expect(tracker.isHandedOff(paneID: Self.pane))
    tracker.paneProcessObserved(paneID: Self.pane, processID: 200)
    #expect(!tracker.isHandedOff(paneID: Self.pane))
  }

  @Test("forget はその pane の記録だけを消す")
  func forgetClearsOnlyThatPane() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    tracker.record(paneID: Self.other, processID: 200)
    #expect(tracker.isHandedOff(paneID: Self.pane))
    tracker.forget(paneID: Self.pane)
    #expect(!tracker.isHandedOff(paneID: Self.pane))
    let forgotten = Self.observe(&tracker, [.working])
    #expect(forgotten == [false])
    #expect(tracker.isHandedOff(paneID: Self.other))
    let other = Self.observe(&tracker, [.working], paneID: Self.other)
    #expect(other == [true])
  }

  @Test("別の pane の pid の違いや状態の遷移は、記録した pane に影響しない")
  func otherPaneDoesNotAffectRecord() {
    var tracker = PaneHandoffTracker()
    tracker.record(paneID: Self.pane, processID: 100)
    tracker.paneProcessObserved(paneID: Self.other, processID: 200)
    let other = Self.observe(&tracker, [.completed, .working], paneID: Self.other)
    #expect(other == [false, false])
    #expect(tracker.isHandedOff(paneID: Self.pane))
  }

  private static func observe(
    _ tracker: inout PaneHandoffTracker, _ states: [AgentState?], paneID: PaneID = pane
  ) -> [Bool] {
    states.map { tracker.update(paneID: paneID, agentState: $0) }
  }
}
