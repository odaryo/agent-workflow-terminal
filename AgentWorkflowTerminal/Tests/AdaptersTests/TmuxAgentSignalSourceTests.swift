import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("tmux Agent signals と ps 生存確認")
struct TmuxAgentSignalSourceTests {
  private let paneID = PaneID(rawValue: "%7")

  @Test("1回の tmux 起動で画面と title の両方を取る")
  func signalsUseOneLaunchForScreenAndTitle() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["screen\n"]], titles: [paneID: ["live title"]])
    let source = try makeSource(spy: spy, clock: ManualTimeSource())

    let signals = try await source.signals(
      for: makePaneSnapshot(id: "%7", pid: 70, title: "stale title"), minimumChangedLines: 1)

    #expect(signals.paneTitle == "live title")
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
    // marker は title 取得を相乗りさせるので、起動は増えない。
    #expect(marker.hasSuffix(TmuxListPanes.agentPaneStatusFormat))
    // `display-message -p` は template のリテラル部を strftime 展開する (tmux 3.4 実測)。
    #expect(!marker.contains("%"))
  }

  /// `AgentAdapter` の既定 `observations(of:)` は毎周期**同じ `PaneSnapshot` 値**を渡し、
  /// `WorktreePaneFeedCoordinator` は `processID` / `currentCommand` / `isDead` が変わらない限り
  /// 観測 Task を作り直さない。よって `PaneSnapshot.title` を信号に使うと、長寿命の agent pane で
  /// title が観測開始時の値に凍る。
  @Test("pane の title が変わったら次の周期の signals に反映される")
  func reflectsLatestPaneTitle() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["a\n", "b\n"]], titles: [paneID: ["⠋ working", "codex"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70, title: "⠋ working")

    let first = try await source.signals(for: pane, minimumChangedLines: 1)
    clock.advance(by: .seconds(2))
    let second = try await source.signals(for: pane, minimumChangedLines: 1)

    #expect(first.paneTitle == "⠋ working")
    #expect(second.paneTitle == "codex")
  }

  /// F1 が利用者に見える形。`CodexAdapter` は title の spinner を画面判定より前に短絡するので、
  /// title が凍ると Working から抜けられなくなる。
  @Test("title の spinner が止まれば Codex の Working も外れる")
  func codexLeavesWorkingWhenSpinnerStops() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["Ask Codex to do anything\n", "Ask Codex to do anything\n"]],
      titles: [paneID: ["⠋ codex", "codex"]])
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let pane = makePaneSnapshot(id: "%7", pid: 70, title: "⠋ codex")
    let codex = CodexAdapter()

    let working = try await source.signals(
      for: pane, minimumChangedLines: codex.minimumChangedLinesForScreenActivity)
    clock.advance(by: .seconds(2))
    let settled = try await source.signals(
      for: pane, minimumChangedLines: codex.minimumChangedLinesForScreenActivity)

    #expect(fixtureState(codex.classify(signals: working, liveness: .alive)) == "working")
    #expect(fixtureState(codex.classify(signals: settled, liveness: .alive)) == "idle")
  }

  /// tmux 3.4 は出力段で `$` の前に `\` を足し、format 側の `s/\\/\\\\/` が値の backslash を
  /// 二重化する。復号は `TmuxListPanes` の既存規則をそのまま通す。
  @Test("title の backslash と $ を復号して返す")
  func decodesEscapedTitle() async throws {
    let spy = ObservationProcessSpy(
      screens: [paneID: ["a\n"]], titles: [paneID: [#"back\slash $dollar"#]])
    let source = try makeSource(spy: spy, clock: ManualTimeSource())

    let signals = try await source.signals(
      for: makePaneSnapshot(id: "%7", pid: 70), minimumChangedLines: 1)

    #expect(signals.paneTitle == #"back\slash $dollar"#)
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

  /// キャッシュが「同じバッチを2周期ぶん配る」ことは無い、という主張。
  ///
  /// - Important: これは**実効サンプル間隔が 2.0 秒以下であることを含意しない**。前回が
  ///   バッチ捕捉直後、今回が TTL 満了直前だと間隔は `signals + TTL` (= 3.0s) まで伸びる。
  ///   §7.5 の検出率が 2.0 秒 polling に対する値である以上、実効間隔の分布は別途計測が要る
  ///   (Issue #239 のレビュー F6)。
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
    let panes = (1...10).map { makePaneSnapshot(id: "%\($0)", pid: Int32($0)) }
    let spy = ObservationProcessSpy(
      screens: Dictionary(uniqueKeysWithValues: panes.map { ($0.id, ["s\n"]) }))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    for pane in panes {
      _ = try await source.signals(for: pane, minimumChangedLines: 1)
      clock.advance(by: .seconds(2))
    }

    // 消えた pane 1件につき再バッチが1回。予算を超えたぶんは今回のバッチでは取れない。
    await spy.setMissing(Set(panes.prefix(9).map(\.id)))
    let signals = try await source.signals(for: panes[9], minimumChangedLines: 1)

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

  /// `.unavailable` は「見に行かなかった」であって「pane が変わった」ではない。基準を捨てると、
  /// その周期の `.screenUnavailable` に加えて**次の周期も** `secondsSinceScreenChange == nil` に
  /// なり、1回の取りこぼしが Unknown 2周期へ増幅する。
  @Test("画面を1周期取りこぼしても変化追跡の基準を捨てない")
  func unavailableKeepsScreenBaseline() async throws {
    let panes = (1...2).map { makePaneSnapshot(id: "%\($0)", pid: Int32($0)) }
    let spy = ObservationProcessSpy(
      screens: Dictionary(uniqueKeysWithValues: panes.map { ($0.id, ["s\n"]) }))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    for pane in panes {
      _ = try await source.signals(for: pane, minimumChangedLines: 1)
      clock.advance(by: .seconds(2))
    }

    // %2 だけ出力上限を超えさせて取りこぼす (pane は生きたまま)。
    await spy.setOversized([panes[1].id])
    let missed = try await source.signals(for: panes[1], minimumChangedLines: 1)
    await spy.setOversized([])
    clock.advance(by: .seconds(2))
    let recovered = try await source.signals(for: panes[1], minimumChangedLines: 1)

    #expect(missed.screenText == nil)
    #expect(missed.secondsSinceScreenChange == nil)
    // 基準が残っていれば、取り直した同じ画面は「変化なし」= 経過時間つきで返る。
    #expect(recovered.screenText == "s\n")
    #expect(recovered.secondsSinceScreenChange != nil)
  }

  /// G1 の実害。`forget` されない pane はバッチに相乗りし続け、1バッチの捕捉対象と出力量が
  /// 単調に増える (起動回数は増えない — バッチは `signals` からしか起きないため)。
  @Test("forget した pane は次のバッチの対象から外れる")
  func forgottenPaneLeavesTheBatch() async throws {
    let panes = (1...3).map { makePaneSnapshot(id: "%\($0)", pid: Int32($0)) }
    let spy = ObservationProcessSpy(
      screens: Dictionary(uniqueKeysWithValues: panes.map { ($0.id, ["s\n"]) }))
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    for pane in panes {
      _ = try await source.signals(for: pane, minimumChangedLines: 1)
      clock.advance(by: .seconds(2))
    }

    await source.forget(panes[1])
    _ = try await source.signals(for: panes[0], minimumChangedLines: 1)

    let invocations = await spy.invocations
    let lastBatch = ObservationProcessSpy.parseBatch(invocations.last ?? [])
    #expect(lastBatch.panes == [panes[0].id, panes[2].id])
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
