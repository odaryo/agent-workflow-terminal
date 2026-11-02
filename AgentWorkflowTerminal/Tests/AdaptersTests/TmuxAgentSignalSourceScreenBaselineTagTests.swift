import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§12.4.2 tmux Agent の画面の基準に付ける Agent の pid の印")
struct TmuxAgentScreenBaselineTagTests {
  private let paneID = PaneID(rawValue: "%7")
  private let claudeTable = "70 1 /bin/sh\n71 70 claude\n"

  @Test("§12.4.2 5秒以上静かだった後に、shell を挟まずに起動し直した Agent の最初の画面の変化は比較対象を持たない")
  func restartedAgentFirstScreenChangeHasNoBaseline() async throws {
    let seconds = try await secondsSinceChangeAfterQuietPeriod(
      quietSeconds: 6, agentProcessIDAtChange: 72)
    #expect(seconds == nil)
  }

  @Test("§12.4.2 静かだった時間が5秒未満なら、変化の採取で ps を読まず、起動し直していても経過は 0")
  func shortQuietPeriodDoesNotCheckProcessTag() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["A\n", "A\n", "B\n"]], processTableOutput: claudeTable)
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    clock.advance(by: .seconds(3))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 3)
    await spy.setProcessTableOutput("70 1 /bin/sh\n72 70 claude\n")
    let readsBeforeChange = await spy.count(of: .ps)
    clock.advance(by: .seconds(3))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)
    let readsAfterChange = await spy.count(of: .ps)
    #expect(changed.screenText == "B\n")
    #expect(changed.secondsSinceScreenChange == 0)
    #expect(changed.hasObservedScreenChange == true)
    #expect(readsAfterChange == readsBeforeChange)
  }

  @Test("§12.4.2 TTL の中に起動し直す前の ps があっても、基準の印は捕捉より後の ps で付ける")
  func baselineTagIgnoresProcessTableReadBeforeCapture() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["A\n", "A\n", "B\n"]], processTableOutput: claudeTable)
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    await spy.setProcessTableOutput("70 1 /bin/sh\n72 70 claude\n")
    clock.advance(by: .seconds(1))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    clock.advance(by: .seconds(6))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 6)
    clock.advance(by: .seconds(3))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(changed.screenText == "B\n")
    #expect(changed.secondsSinceScreenChange == 0)
  }

  @Test("§12.4.2 同じ Agent のプロセスが静かな状態から変われば経過は 0")
  func sameAgentTurnStartIsZero() async throws {
    let seconds = try await secondsSinceChangeAfterQuietPeriod(
      quietSeconds: 2, agentProcessIDAtChange: 71)
    #expect(seconds == 0)
  }

  @Test("§12.4.2 画面が変わり続けている間は ps を読み足さない")
  func continuouslyChangingScreenDoesNotReadProcessTable() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["0\n", "1\n", "2\n", "3\n", "4\n"]], processTableOutput: claudeTable)
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    let readsAfterBaseline = await spy.count(of: .ps)
    for _ in 1..<5 {
      clock.advance(by: .seconds(3))
      #expect(
        try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 0)
    }
    let readsAfterSteadyState = await spy.count(of: .ps)
    #expect(readsAfterSteadyState == readsAfterBaseline)
  }

  @Test("§12.4.2 画面が静かな間は ps を読み足さない")
  func quietScreenDoesNotReadProcessTable() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["A\n"]], processTableOutput: claudeTable)
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    let readsAfterBaseline = await spy.count(of: .ps)
    for step in 1..<5 {
      clock.advance(by: .seconds(3))
      #expect(
        try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange
          == TimeInterval(3 * step))
    }
    let readsAfterSteadyState = await spy.count(of: .ps)
    #expect(readsAfterSteadyState == readsAfterBaseline)
  }

  @Test("§12.4.2 ps が読めない間に作った基準は、最初の画面の変化で比較対象から外す")
  func baselineWithoutProcessTagIsReplacedAtFirstChange() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["A\n", "A\n", "B\n"]], processTableOutput: claudeTable)
    await spy.setProcessTableFailure(
      ProcessRunResult(exitCode: 1, stdout: "", stderr: "ps: failed\n"))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .undetermined)
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    await spy.setProcessTableFailure(nil)
    clock.advance(by: .seconds(6))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 6)
    clock.advance(by: .seconds(3))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(changed.screenText == "B\n")
    #expect(changed.secondsSinceScreenChange == nil)
  }

  @Test("§12.4.2 静かな状態から変わったときに ps が読めなければ画面の履歴を保つ")
  func unreadableProcessTableAtChangeKeepsScreenHistory() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["A\n", "A\n", "B\n"]], processTableOutput: claudeTable)
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    clock.advance(by: .seconds(6))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 6)
    await spy.setProcessTableFailure(
      ProcessRunResult(exitCode: 1, stdout: "", stderr: "ps: failed\n"))
    let readsBeforeChange = await spy.count(of: .ps)
    clock.advance(by: .seconds(3))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)
    let readsAfterChange = await spy.count(of: .ps)
    #expect(changed.screenText == "B\n")
    #expect(changed.secondsSinceScreenChange == 0)
    #expect(readsAfterChange == readsBeforeChange + 1)
  }

  @Test("§12.4.2 同じ時刻に捕捉した2つの pane の基準は ps を1回で済ませる")
  func panesCapturedTogetherShareProcessTableRead() async throws {
    let otherPaneID = PaneID(rawValue: "%8")
    let spy = ObservationProcessSpy(
      screens: [paneID: ["A\n"], otherPaneID: ["B\n"]],
      processTableOutput: "70 1 /bin/sh\n71 70 claude\n80 1 /bin/sh\n81 80 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    let otherPane = makePaneSnapshot(id: "%8", pid: 80)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    #expect(await source.liveness(for: otherPane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    let readsBeforeBaseline = await spy.count(of: .ps)
    async let first = source.signals(for: pane, minimumChangedLines: 1)
    async let second = source.signals(for: otherPane, minimumChangedLines: 1)
    let (firstSignals, secondSignals) = try await (first, second)
    #expect(firstSignals.secondsSinceScreenChange == nil)
    #expect(secondSignals.secondsSinceScreenChange == nil)
    let readsAfterBaseline = await spy.count(of: .ps)
    #expect(readsAfterBaseline == readsBeforeBaseline + 1)
  }

  /// 基準 → 静か (`quietSeconds` 秒) → 画面の変化、の順に採取する。変化の直前に Agent の pid を
  /// `agentProcessIDAtChange` へ差し替えるが、`liveness` は引かない (前景のコマンドが変わらず、
  /// 再選択が起きない形)。時計は変化の前に ps の TTL を越えて進める。
  private func secondsSinceChangeAfterQuietPeriod(
    quietSeconds: Int, agentProcessIDAtChange: Int32
  ) async throws -> TimeInterval? {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["A\n", "A\n", "B\n"]], processTableOutput: claudeTable)
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    clock.advance(by: .seconds(quietSeconds))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange
        == TimeInterval(quietSeconds))
    await spy.setProcessTableOutput("70 1 /bin/sh\n\(agentProcessIDAtChange) 70 claude\n")
    clock.advance(by: .seconds(3))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(changed.screenText == "B\n")
    return changed.secondsSinceScreenChange
  }
}
