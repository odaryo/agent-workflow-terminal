import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§12.4.2 tmux Agent の画面履歴の持ち主と引き継ぎ")
struct TmuxAgentScreenOwnershipTests {
  private let paneID = PaneID(rawValue: "%7")

  @Test("§12.4.2 別の種類の名前で absent を引いても同じプロセスの画面履歴を保つ")
  func otherAgentAbsenceKeepsScreenHistory() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["screen\n"]], processTableOutput: "70 1 /bin/sh\n71 70 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["codex"]) == .absent)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(2))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 2)
  }

  @Test(
    "§12.4.2 プロセスが変わるか持ち主の候補が1つから2つに変われば画面履歴を捨てる",
    arguments: ["70 1 /bin/sh\n72 70 claude\n", "70 1 /bin/sh\n71 70 claude\n72 70 claude\n"])
  func changedOrAmbiguousProcessForgetsScreenHistory(processTable: String) async throws {
    let spy = SignalProcessTableSpy()
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(3))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 3)
    await spy.setProcessTableOutput(processTable)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    clock.advance(by: .seconds(2))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
  }

  @Test("§12.4.2 同じ深さの持ち主の候補が2つのままなら画面履歴を保つ")
  func unchangedMultipleCandidatesKeepScreenHistory() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["screen\n"]],
      processTableOutput: "70 1 /bin/sh\n71 70 /opt/tools/claude\n72 70 /opt/tools/claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    let first = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(2))
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    let second = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(first.secondsSinceScreenChange == nil)
    #expect(second.secondsSinceScreenChange == 2)
  }

  @Test("§12.4.2 名前の集合ごとに持ち主の pid が違っても画面履歴を保つ")
  func distinctAgentNameOwnersKeepScreenHistory() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["screen\n"]],
      processTableOutput: "70 1 /bin/sh\n71 70 /opt/tools/claude\n72 71 /opt/tools/codex\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["codex"]) == .alive)
    let first = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(2))
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["codex"]) == .alive)
    let second = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(first.secondsSinceScreenChange == nil)
    #expect(second.secondsSinceScreenChange == 2)
  }

  @Test("§12.4.2 別の種類の Agent に入れ替われば画面履歴を捨てる")
  func replacedAgentKindForgetsScreenHistory() async throws {
    let spy = SignalProcessTableSpy()
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .alive)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    await spy.setProcessTableOutput("70 1 /bin/sh\n73 70 /opt/tools/codex\n")
    clock.advance(by: .seconds(3))
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .absent)
    #expect(await source.liveness(for: pane, matchingProcessNames: ["codex"]) == .alive)
    let signals = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(signals.screenText == "screen\n")
    #expect(signals.secondsSinceScreenChange == nil)
  }

  @Test("§12.4.2 猶予の間に戻った pane は猶予を過ぎても画面履歴を保つ")
  func returningPaneKeepsScreenHistoryBeyondGrace() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["screen\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    await source.forget(pane)
    clock.advance(by: .seconds(5))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 5)
    clock.advance(by: .seconds(6))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 11)
  }

  @Test("§12.4.2 ちょうど10秒で戻った pane は画面履歴を保つ")
  func returningPaneAtGraceBoundaryKeepsScreenHistory() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["screen\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    await source.forget(pane)
    clock.advance(by: .seconds(10))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == 10)
  }

  @Test("§12.4.2 forget 後の画面履歴は10秒以内の復帰で引き継ぎ超過で捨てる", arguments: [9, 11])
  func forgottenScreenHistoryExpiresAfterGrace(seconds: Int) async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["screen\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    await source.forget(pane)
    clock.advance(by: .seconds(seconds))
    let signals = try await source.signals(for: pane, minimumChangedLines: 1)
    #expect(signals.screenText == "screen\n")
    #expect(signals.secondsSinceScreenChange == (seconds == 9 ? 9 : nil))
  }

  @Test("§12.4.2 dead な pane の画面履歴はすぐに捨てる")
  func deadPaneForgetsScreenHistory() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["screen\n"]], processTableOutput: "70 1 /bin/sh\n71 70 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = PaneSnapshot(
      id: paneID, processID: 70, tty: "", currentCommand: "", currentPath: "", title: "",
      termination: .exited(status: 0))
    #expect(pane.isDead)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(2))
    #expect(await source.liveness(for: pane, matchingProcessNames: ["claude"]) == .absent)
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
  }
}

private actor SignalProcessTableSpy: ProcessRunning {
  private let observations = ObservationProcessSpy(screens: [PaneID(rawValue: "%7"): ["screen\n"]])
  private var processTableOutput = "70 1 /bin/sh\n71 70 claude\n"

  func setProcessTableOutput(_ output: String) { processTableOutput = output }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    if executableURL.lastPathComponent == "ps" {
      return ProcessRunResult(exitCode: 0, stdout: processTableOutput, stderr: "")
    }
    return try await observations.run(
      executableURL: executableURL, arguments: arguments, environment: environment,
      timeout: timeout, outputLimit: outputLimit)
  }
}
