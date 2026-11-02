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
}
