import Foundation
import Testing

@testable import TerminalCore

@Suite("§12.3 画面の変化の観測")
struct AgentScreenChangeObservationTests {
  private let paneID = PaneID(rawValue: "%1")

  @Test("変化を観測した後は、1秒以内に静かな採取が続いても観測済みのまま Working (Issue #560)")
  func observedChangeSurvivesConsecutiveQuietSamples() {
    let now = ContinuousClock().now
    let adapter = ClaudeCodeAdapter()
    let minimumChangedLines = adapter.minimumChangedLinesForScreenActivity
    var tracker = AgentScreenChangeTracker()
    _ = tracker.observeChange(
      screen: "a\nb\nc", paneID: paneID, at: now, minimumChangedLines: minimumChangedLines)
    let changed = tracker.observeChange(
      screen: "A\nB\nc", paneID: paneID, at: now.advanced(by: .seconds(2)),
      minimumChangedLines: minimumChangedLines)
    let firstQuiet = tracker.observeChange(
      screen: "A\nB\nc", paneID: paneID, at: now.advanced(by: .milliseconds(2_250)),
      minimumChangedLines: minimumChangedLines)
    let secondQuiet = tracker.observeChange(
      screen: "A\nB\nc", paneID: paneID, at: now.advanced(by: .milliseconds(2_500)),
      minimumChangedLines: minimumChangedLines)
    #expect(changed?.hasObservedChange == true)
    #expect(firstQuiet?.hasObservedChange == true)
    #expect(secondQuiet?.hasObservedChange == true)
    #expect(secondQuiet?.secondsSinceChange == 0.5)
    let result = adapter.classify(
      signals: AgentSignals(
        paneTitle: "", screenText: "A\nB\nc", styledScreenText: nil,
        secondsSinceScreenChange: secondQuiet?.secondsSinceChange,
        hasObservedScreenChange: secondQuiet?.hasObservedChange ?? false,
        observedAt: .distantPast),
      liveness: .alive)
    guard case .observation(let observation) = result else {
      Issue.record("absent")
      return
    }
    #expect(observation.state == .working)
  }

  @Test("基準の採取は観測を返さない (Issue #560)")
  func baselineHasNoObservation() {
    var tracker = AgentScreenChangeTracker()
    #expect(tracker.observeChange(screen: "a\nb", paneID: paneID, at: ContinuousClock().now) == nil)
  }

  @Test("出力とみなす変化の採取は、今回が出力である (Issue #560)")
  func changedSampleIsOutput() {
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    _ = tracker.observeChange(screen: "a\nb", paneID: paneID, at: now)
    let changed = tracker.observeChange(
      screen: "a\nB", paneID: paneID, at: now.advanced(by: .seconds(1)))
    #expect(changed?.isOutput == true)
  }

  @Test("静かな採取は、変化を観測した後でも今回は出力ではない (Issue #560)")
  func quietSampleIsNotOutput() {
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    _ = tracker.observeChange(screen: "a\nb", paneID: paneID, at: now)
    let quietBeforeChange = tracker.observeChange(
      screen: "a\nb", paneID: paneID, at: now.advanced(by: .seconds(1)))
    _ = tracker.observeChange(screen: "a\nB", paneID: paneID, at: now.advanced(by: .seconds(2)))
    let quietAfterChange = tracker.observeChange(
      screen: "a\nB", paneID: paneID, at: now.advanced(by: .seconds(2)))
    #expect(quietBeforeChange?.isOutput == false)
    #expect(quietAfterChange?.isOutput == false)
    #expect(quietAfterChange?.secondsSinceChange == 0)
  }
}
