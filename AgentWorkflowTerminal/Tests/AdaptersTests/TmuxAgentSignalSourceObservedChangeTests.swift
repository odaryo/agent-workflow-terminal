import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§12.3 tmux Agent の画面の変化を観測したかどうか")
struct TmuxAgentObservedScreenChangeTests {
  private let paneID = PaneID(rawValue: "%7")

  @Test("同じバッチで2回採取しても、画面の変化を観測したことにしない (Issue #559)")
  func secondSignalsFromSameBatchHasNotObservedChange() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["A\n"]], processTableOutput: "70 1 /bin/sh\n71 70 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    let baseline = try await source.signals(for: pane, minimumChangedLines: 2)
    let repeated = try await source.signals(for: pane, minimumChangedLines: 2)
    #expect(await spy.batchCount == 1)
    #expect(baseline.secondsSinceScreenChange == nil)
    #expect(repeated.screenText == "A\n")
    #expect(repeated.secondsSinceScreenChange == 0)
    #expect(repeated.hasObservedScreenChange == false)
  }

  @Test("変化を観測した後に同じバッチを続けて採取しても、観測済みのまま Working (Issue #560)")
  func repeatedSignalsAfterChangeStayObserved() async throws {
    let adapter = ClaudeCodeAdapter()
    let minimumChangedLines = adapter.minimumChangedLinesForScreenActivity
    let spy = ObservationProcessSpy(
      screens: [paneID: ["a\nb\nc\n", "A\nB\nc\n"]],
      processTableOutput: "70 1 /bin/sh\n71 70 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    let baseline = try await source.signals(for: pane, minimumChangedLines: minimumChangedLines)
    clock.advance(by: .seconds(2))
    let changed = try await source.signals(for: pane, minimumChangedLines: minimumChangedLines)
    clock.advance(by: .milliseconds(250))
    let firstRepeat = try await source.signals(for: pane, minimumChangedLines: minimumChangedLines)
    clock.advance(by: .milliseconds(250))
    let secondRepeat = try await source.signals(for: pane, minimumChangedLines: minimumChangedLines)
    #expect(await spy.batchCount == 2)
    #expect(baseline.secondsSinceScreenChange == nil)
    #expect(changed.secondsSinceScreenChange == 0)
    #expect(changed.hasObservedScreenChange == true)
    #expect(firstRepeat.hasObservedScreenChange == true)
    #expect(secondRepeat.screenText == "A\nB\nc\n")
    #expect(secondRepeat.secondsSinceScreenChange == 0)
    #expect(secondRepeat.hasObservedScreenChange == true)
    guard
      case .observation(let observation) = adapter.classify(
        signals: secondRepeat, liveness: .alive)
    else {
      Issue.record("absent")
      return
    }
    #expect(observation.state == .working)
  }
}
