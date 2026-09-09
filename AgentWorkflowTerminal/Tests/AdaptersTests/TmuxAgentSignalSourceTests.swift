import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("tmux Agent signals と ps 生存確認")
struct TmuxAgentSignalSourceTests {
  private let paneID = PaneID(rawValue: "%7")

  @Test("1回の tmux 起動で画面を取り、title は pane 一覧の値をそのまま使う")
  func signalsUseOneLaunchAndListPanesTitle() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["screen\n"]])
    let source = try makeSource(spy: spy, clock: ManualTimeSource())

    let signals = try await source.signals(
      for: makePaneSnapshot(id: "%7", pid: 70, title: "title"), minimumChangedLines: 1)

    #expect(signals.paneTitle == "title")
    #expect(signals.screenText == "screen\n")
    #expect(signals.secondsSinceScreenChange == nil)
    let invocations = await spy.invocations
    #expect(invocations.count == 1)
    let marker = try #require(invocations[0].last)
    #expect(
      invocations[0].suffix(11)
        == [
          "capture-pane", "-e", "-p", "-t", "%7",
          ";", "display-message", "-t", "%7", "-p", marker,
        ])
    #expect(marker.hasSuffix(" #{pane_id}"))
    #expect(!marker.contains("%"))
    // title を取るためだけの `display-message` は無くなった。
    #expect(!invocations.contains { $0.contains(TmuxListPanes.agentPaneStatusFormat) })
  }

  @Test("登録済みの複数 pane を1プロセスでまとめて取る")
  func batchesRegisteredPanes() async throws {
    let panes = (1...3).map { makePaneSnapshot(id: "%\($0)", pid: Int32($0)) }
    let spy = ObservationProcessSpy(
      screens: Dictionary(uniqueKeysWithValues: panes.map { ($0.id, ["s\($0.id.rawValue)\n"]) }))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)

    // 1周目は登録が増えるたびにバッチを起こす。
    for pane in panes {
      _ = try await source.signals(for: pane, minimumChangedLines: 1)
      clock.advance(by: .seconds(2))
    }
    let launchesAfterRegistration = await spy.kinds.count

    // 2周目は同じ TTL 窓に収まるので、3 pane ぶんを1起動で賄う。
    var screens: [String?] = []
    for pane in panes {
      screens.append(try await source.signals(for: pane, minimumChangedLines: 1).screenText)
    }

    let added = await Array(spy.kinds.suffix(from: launchesAfterRegistration))
    #expect(added == [.captureBatch(paneCount: 3)])
    #expect(screens == ["s%1\n", "s%2\n", "s%3\n"])
  }

  /// §7.5 の検出率は 2.0 秒 polling に対する値なので、キャッシュが実効間隔を伸ばしてはならない。
  @Test("同じ pane が周期どおりに2回呼ぶと必ず別のバッチを読む")
  func consecutivePollsReadDistinctBatches() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["a\n", "b\n", "c\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    let intervals = AgentObservationIntervals(signals: .seconds(2), liveness: .seconds(5))

    var screens: [String?] = []
    for _ in 0..<3 {
      screens.append(try await source.signals(for: pane, minimumChangedLines: 1).screenText)
      clock.advance(by: intervals.signals)
    }

    #expect(screens == ["a\n", "b\n", "c\n"])
    #expect(await spy.captureBatchCount == 3)
  }

  @Test("TTL の内側で来た同じ pane の呼び出しは起動を増やさない")
  func reusesBatchWithinTimeToLive() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["a\n", "b\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)

    _ = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .milliseconds(500))
    let second = try await source.signals(for: pane, minimumChangedLines: 1)

    #expect(second.screenText == "a\n")
    #expect(await spy.captureBatchCount == 1)
  }

  @Test("画面差分から pane 単位の最終変化時刻を追跡する")
  func tracksScreenChanges() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["first\n", "first\n", "second\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)

    let first = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(2))
    let unchanged = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(2))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)

    #expect(first.secondsSinceScreenChange == nil)
    #expect(unchanged.secondsSinceScreenChange == 2)
    #expect(changed.secondsSinceScreenChange == 0)
  }

  @Test("しきい値 2 では1行だけ違う画面が続いても鮮度を 0 に戻さない")
  func honorsMinimumChangedLines() async throws {
    // idle 真値区間で実際に観測されたステータス行の遷移 (Spikes/gate3/README.md §13.0) と、
    // 2 行が動く出力。
    let statusLines = [
      "● high · /effort",
      "tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf and reattach"
        + " for focus tracking",
      "",
    ]
    let spy = ObservationProcessSpy(
      screens: [
        paneID: statusLines.map { "❯ \n\($0)\n" } + ["⏺ writing\n· done 3 lines\n"]
      ])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)

    var observed: [TimeInterval?] = []
    for _ in 0..<4 {
      observed.append(
        try await source.signals(for: pane, minimumChangedLines: 2).secondsSinceScreenChange)
      clock.advance(by: .seconds(2))
    }

    #expect(observed == [nil, 2, 4, 0])
  }

  @Test("生産した画面変化信号がそのまま Claude の Working 判定へ届く")
  func connectsSignalProducerToClassifier() async throws {
    let spy = ObservationProcessSpy(screens: [paneID: ["first frame\n", "second frame\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)

    let initial = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(2))
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)

    #expect(
      fixtureState(ClaudeCodeAdapter().classify(signals: initial, liveness: .alive)) == "unknown")
    #expect(
      fixtureState(ClaudeCodeAdapter().classify(signals: changed, liveness: .alive)) == "working")
  }

  @Test("absent を観測した pane の画面履歴を解放する")
  func absentForgetsScreen() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["screen\n"]], processTableOutput: "70 1 /bin/sh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)

    #expect(await source.liveness(for: pane, matchingProcessNames: ["agent"]) == .absent)
    clock.advance(by: .seconds(2))
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
  }

  @Test("消えた pane は握り潰さず paneNotFound として報告する")
  func missingPaneIsReported() async throws {
    let panes = [makePaneSnapshot(id: "%7", pid: 70), makePaneSnapshot(id: "%8", pid: 80)]
    let spy = ObservationProcessSpy(
      screens: [PaneID(rawValue: "%7"): ["gone\n"], PaneID(rawValue: "%8"): ["alive\n"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    for pane in panes {
      _ = try await source.signals(for: pane, minimumChangedLines: 1)
      clock.advance(by: .seconds(2))
    }

    await spy.setMissing([PaneID(rawValue: "%7")])
    await #expect(throws: TmuxAgentSignalSourceError.paneNotFound(PaneID(rawValue: "%7"))) {
      try await source.signals(for: panes[0], minimumChangedLines: 1)
    }
    // 消えた pane がいても、残りの pane は同じバッチで画面を取れている。
    #expect(
      try await source.signals(for: panes[1], minimumChangedLines: 1).screenText == "alive\n")
  }

  /// 起動上限に達して今回のバッチで取れなかった pane は、`paneNotFound` ではなく
  /// 「画面だけ無い」信号として Adapter へ渡す。
  @Test("バッチの起動上限に達した pane は画面利用不能として扱う")
  func exhaustedBatchBudgetIsScreenUnavailable() async throws {
    let panes = (1...6).map { makePaneSnapshot(id: "%\($0)", pid: Int32($0)) }
    let spy = ObservationProcessSpy(
      screens: Dictionary(uniqueKeysWithValues: panes.map { ($0.id, ["s\n"]) }))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    for pane in panes {
      _ = try await source.signals(for: pane, minimumChangedLines: 1)
      clock.advance(by: .seconds(2))
    }

    await spy.setMissing(Set(panes.prefix(5).map(\.id)))
    let signals = try await source.signals(for: panes[5], minimumChangedLines: 1)

    #expect(signals.screenText == nil)
    guard
      case .observation(let observation) = ClaudeCodeAdapter().classify(
        signals: signals, liveness: .alive)
    else {
      Issue.record("状態観測が必要")
      return
    }
    #expect(observation.unknownReason == .screenUnavailable)
  }

  @Test("pane_pid 自身が一致すれば子がいなくても alive")
  func rootProcessIsAlive() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /opt/tools/agent\n")
    let source = try makeSource(spy: spy, clock: ManualTimeSource())
    #expect(
      await source.liveness(
        for: makePaneSnapshot(id: "%7", pid: 70), matchingProcessNames: ["agent"]
      ) == .alive
    )
  }

  @Test("フルパスと空白を保った comm を process 名として照合する")
  func parsesFullPathWithSpaces() async throws {
    let spy = ObservationProcessSpy(
      processTableOutput: "70 1 /bin/sh\n71 70 /Applications/Agent Tool\n")
    let source = try makeSource(spy: spy, clock: ManualTimeSource())
    #expect(
      await source.liveness(
        for: makePaneSnapshot(id: "%7", pid: 70), matchingProcessNames: ["Agent Tool"]
      ) == .alive
    )
  }

  @Test("不正な pane ID は tmux に渡さない")
  func rejectsInvalidPaneID() async throws {
    let spy = ObservationProcessSpy()
    let source = try makeSource(spy: spy, clock: ManualTimeSource())
    await #expect(throws: TmuxAgentSignalSourceError.self) {
      try await source.signals(
        for: makePaneSnapshot(id: "session", pid: 70), minimumChangedLines: 1)
    }
    #expect(await spy.invocations.isEmpty)
  }

  private func makeSource(
    spy: ObservationProcessSpy, clock: ManualTimeSource
  ) throws -> TmuxAgentSignalSource {
    TmuxAgentSignalSource(
      processTable: ProcessTableSnapshotCache(
        processRunner: spy, executableURL: URL(fileURLWithPath: "/ps"),
        timeToLive: ProcessTableSnapshotCache.defaultTimeToLive, timeSource: clock),
      screenBatcher: TmuxPaneScreenBatcher(
        runner: try makeTmuxRunner(socketName: "signals-test", processRunner: spy),
        timeToLive: TmuxPaneScreenBatcher.defaultTimeToLive, timeSource: clock)
    )
  }
}

private func fixtureState(_ result: AgentObservationResult) -> String {
  switch result {
  case .absent: "absent"
  case .observation(let observation): observation.state.rawValue
  }
}
