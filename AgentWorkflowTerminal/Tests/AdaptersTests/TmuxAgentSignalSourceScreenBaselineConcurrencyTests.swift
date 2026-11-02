import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§12.4.2 tmux Agent の画面の基準の印と、同じ pane への並行の採取")
struct TmuxAgentScreenBaselineConcurrencyTests {
  private let paneID = PaneID(rawValue: "%7")
  private let claudeTable = "70 1 /bin/sh\n71 70 claude\n"
  private let restartedClaudeTable = "70 1 /bin/sh\n72 70 claude\n"

  @Test("§12.4.2 基準の印の ps を待つ間に基準が作り直されたら、遅れて戻った ps で新しい基準に印を付けない")
  func lateBaselineTagDoesNotOverwriteRebuiltBaseline() async throws {
    let spy = HeldProcessTableSpy(
      ObservationProcessSpy(
        screens: [paneID: ["A\n", "A\n", "A\n", "B\n"]], processTableOutput: claudeTable))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    await spy.holdNextProcessTableRead()
    async let held = source.signals(for: pane, minimumChangedLines: 1)
    let isHeld = await spy.waitUntilHeld()
    await spy.base.setProcessTableOutput(restartedClaudeTable)
    await source.forget(pane)
    clock.advance(by: .seconds(11))
    let rebuilt = try? await source.signals(for: pane, minimumChangedLines: 1)
    await spy.release()
    let heldSignals = try await held
    try #require(isHeld)
    #expect(heldSignals.secondsSinceScreenChange == nil)
    #expect(rebuilt?.screenText == "A\n")
    #expect(rebuilt?.secondsSinceScreenChange == nil)
    clock.advance(by: .seconds(6))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 6)
    clock.advance(by: .seconds(3))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(changed.screenText == "B\n")
    #expect(changed.secondsSinceScreenChange == 0)
  }

  @Test("§12.4.2 印を確かめる ps を待つ間に基準が作り直されたら、新しい基準の印と比べない")
  func lateCheckDoesNotCompareWithRebuiltBaseline() async throws {
    let spy = HeldProcessTableSpy(
      ObservationProcessSpy(
        screens: [paneID: ["A\n", "A\n", "B\n", "C\n"]], processTableOutput: claudeTable))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
    clock.advance(by: .seconds(6))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 6)
    clock.advance(by: .seconds(3))
    await spy.holdNextProcessTableRead()
    async let held = source.signals(for: pane, minimumChangedLines: 1)
    let isHeld = await spy.waitUntilHeld()
    await spy.base.setProcessTableOutput(restartedClaudeTable)
    await source.forget(pane)
    clock.advance(by: .seconds(11))
    let rebuilt = try? await source.signals(for: pane, minimumChangedLines: 1)
    await spy.release()
    let heldSignals = try await held
    try #require(isHeld)
    #expect(rebuilt?.screenText == "C\n")
    #expect(rebuilt?.secondsSinceScreenChange == nil)
    #expect(heldSignals.screenText == "B\n")
    #expect(heldSignals.secondsSinceScreenChange == 0)
  }

  @Test("§12.4.2 基準の印の ps が戻る前の、静かな状態から変わった採取は捨てない")
  func changeBeforeBaselineTagArrivesKeepsScreenHistory() async throws {
    let spy = HeldProcessTableSpy(
      ObservationProcessSpy(
        screens: [paneID: ["A\n", "A\n", "B\n"]], processTableOutput: claudeTable))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(3))
    await spy.holdNextProcessTableRead()
    async let held = source.signals(for: pane, minimumChangedLines: 1)
    let isHeld = await spy.waitUntilHeld()
    clock.advance(by: .seconds(6))
    let quiet = try? await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(3))
    let changed = try? await source.signals(for: pane, minimumChangedLines: 1)
    await spy.release()
    let baseline = try await held
    try #require(isHeld)
    #expect(baseline.secondsSinceScreenChange == nil)
    #expect(quiet?.secondsSinceScreenChange == 6)
    #expect(changed?.screenText == "B\n")
    #expect(changed?.secondsSinceScreenChange == 0)
  }
}

/// 次の1回の `ps` を、`release()` まで止める `ProcessRunning`。止めた起動も、応答は起動した時点の
/// table で作る (`ps` は起動した時点のプロセスを読むので)。それ以外の起動はそのまま `base` へ渡す。
///
/// 止めた起動は、`release()` が来なくても実時間で 5 秒経てば戻る。止めている間に別の呼び出しが
/// その `ps` へ合流すると、テストが `release()` まで進めず、失敗せずに止まり続けるため。
private actor HeldProcessTableSpy: ProcessRunning {
  private static let holdLimit = Duration.seconds(5)

  let base: ObservationProcessSpy
  private var holdsNextProcessTableRead = false
  private var isHoldingRead = false
  private var isReleased = false

  init(_ base: ObservationProcessSpy) {
    self.base = base
  }

  func holdNextProcessTableRead() {
    holdsNextProcessTableRead = true
    isReleased = false
  }

  /// 止めた起動が届くまで、実時間で最大 5 秒待つ。届かなければ `false`。
  func waitUntilHeld() async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: Self.holdLimit)
    while !isHoldingRead, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return isHoldingRead
  }

  func release() {
    isReleased = true
    holdsNextProcessTableRead = false
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    // 判定と旗の解除を、`base` を待つ前に済ませる。待つ間に届いた別の `ps` まで止めないため。
    let holds = executableURL.lastPathComponent == "ps" && holdsNextProcessTableRead
    if holds { holdsNextProcessTableRead = false }
    let result = try await base.run(
      executableURL: executableURL, arguments: arguments, environment: environment,
      timeout: timeout, outputLimit: outputLimit)
    guard holds else { return result }
    isHoldingRead = true
    let deadline = ContinuousClock.now.advanced(by: Self.holdLimit)
    while !isReleased, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    isHoldingRead = false
    return result
  }
}
