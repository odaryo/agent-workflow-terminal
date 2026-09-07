import Foundation
import Testing

@testable import TerminalCore

@Suite("Agent Adapter の共通不変条件")
struct AgentAdapterTests {
  private let signals = AgentSignals(
    paneTitle: "",
    screenText: "stale screen",
    secondsSinceScreenChange: 0,
    observedAt: Date(timeIntervalSince1970: 1)
  )

  @Test("不在なら画面に関係なく状態を返さない")
  func absentHasNoState() {
    #expect(ClaudeCodeAdapter().classify(signals: signals, liveness: .absent) == .absent)
    #expect(CodexAdapter().classify(signals: signals, liveness: .absent) == .absent)
    #expect(
      ProcessDetectionFallbackAdapter(processNames: ["agent"])
        .classify(signals: signals, liveness: .absent) == .absent
    )
  }

  @Test("fallback は生存中でも Working と Idle を推測しない")
  func fallbackIsUnknown() {
    let result = ProcessDetectionFallbackAdapter(processNames: ["agent"])
      .classify(signals: signals, liveness: .alive)
    guard case .observation(let observation) = result else {
      Issue.record("状態観測が必要")
      return
    }
    #expect(observation.state == .unknown)
    #expect(observation.unknownReason == .adapterUndetermined)
  }

  @Test("生存確認不能は信号欠落と区別する")
  func livenessUnavailableReason() {
    let result = ClaudeCodeAdapter().classify(signals: signals, liveness: .undetermined)
    guard case .observation(let observation) = result else {
      Issue.record("状態観測が必要")
      return
    }
    #expect(observation.unknownReason == .livenessUnavailable)
  }

  @Test("resolver は最初に生存確認できた Adapter を選ぶ")
  func resolverPriority() {
    let pane = PaneSnapshot(
      id: PaneID(rawValue: "%1"), processID: 1, tty: "", currentCommand: "",
      currentPath: "", title: "", termination: nil
    )
    let fallback = ProcessDetectionFallbackAdapter(processNames: ["agent"])
    let resolved = AgentAdapterResolver.resolve(
      pane: pane,
      candidates: [
        AgentAdapterCandidate(adapter: ClaudeCodeAdapter(), liveness: .absent),
        AgentAdapterCandidate(adapter: CodexAdapter(), liveness: .alive),
      ],
      fallback: fallback
    )
    #expect(resolved.id == CodexAdapter().id)
  }

  @Test("実測 fixture の分類結果は Error を返さない")
  func fixturesNeverInferError() throws {
    for fixture in try AgentStateFixture.load(prefix: "claude-") {
      let result = ClaudeCodeAdapter().classify(
        signals: fixture.signals, liveness: fixture.liveness
      )
      assertNeverError(result, fixture: fixture)
    }
    for fixture in try AgentStateFixture.load(prefix: "codex-") {
      let result = CodexAdapter().classify(
        signals: fixture.signals, liveness: fixture.liveness
      )
      assertNeverError(result, fixture: fixture)
    }
  }

  @Test("観測の Needs Attention category を代表状態まで保つ")
  func preservesObservationCategory() {
    let observation = AgentStateObservation(
      state: .unknown, adapterID: AgentAdapterID(rawValue: "test"),
      observedAt: Date(timeIntervalSince1970: 1), category: .needsAttention,
      lastKnownAt: Date(timeIntervalSince1970: 0), diagnostics: "details",
      unknownReason: .adapterUndetermined
    )
    let representative = resolveWorktreeRepresentativeState(panes: [
      PaneAgentState(id: PaneID(rawValue: "%1"), observation: observation)
    ])
    #expect(representative?.category == .needsAttention)
    #expect(representative?.state == .unknown)
    let pane = PaneAgentState(id: PaneID(rawValue: "%1"), observation: observation)
    #expect(pane.adapterID == observation.adapterID)
    #expect(pane.lastKnownAt == observation.lastKnownAt)
    #expect(pane.unknownReason == observation.unknownReason)
    #expect(pane.diagnostics == observation.diagnostics)
    #expect(pane.lastUpdatedAt == observation.observedAt)
  }

  @Test("diagnostics が変わっても同じ Unknown 状態を再配信しない")
  func diagnosticsDoNotDriveEvents() {
    let first = AgentObservationResult.observation(
      AgentStateObservation(
        state: .unknown, adapterID: AgentAdapterID(rawValue: "test"),
        observedAt: Date(timeIntervalSince1970: 1), diagnostics: "first",
        unknownReason: .observationFailed
      )
    )
    let second = AgentObservationResult.observation(
      AgentStateObservation(
        state: .unknown, adapterID: AgentAdapterID(rawValue: "test"),
        observedAt: Date(timeIntervalSince1970: 2), diagnostics: "second",
        unknownReason: .observationFailed
      )
    )
    #expect(second.hasSameObservableState(as: first))
  }

  @Test("観測失敗でも直前の確定時刻を保つ")
  func observationFailurePreservesLastKnownAt() async {
    let pane = PaneSnapshot(
      id: PaneID(rawValue: "%1"), processID: 1, tty: "", currentCommand: "",
      currentPath: "", title: "", termination: nil
    )
    let stream = ClaudeCodeAdapter().observations(
      of: pane, from: KnownThenFailingSignalSource(),
      intervals: AgentObservationIntervals(
        signals: .milliseconds(1), liveness: .seconds(1)
      )
    )
    var iterator = stream.makeAsyncIterator()
    guard
      case .observation(let known) = await iterator.next(),
      case .observation(let failed) = await iterator.next()
    else {
      Issue.record("確定観測と失敗観測が必要")
      return
    }
    #expect(known.state == .idle)
    #expect(failed.unknownReason == .observationFailed)
    #expect(failed.lastKnownAt == known.observedAt)
  }

  @Test("画面履歴を忘れた pane は次回を初回観測として扱う")
  func screenTrackerForgetsPane() {
    let paneID = PaneID(rawValue: "%1")
    let clock = ContinuousClock()
    var tracker = AgentScreenChangeTracker()
    let now = clock.now
    #expect(tracker.observe(screen: "screen", paneID: paneID, at: now) == nil)
    tracker.forget(paneID: paneID)
    #expect(tracker.observe(screen: "screen", paneID: paneID, at: now) == nil)
  }

  @Test("既定のしきい値 1 では1文字の差も画面変化として扱う")
  func screenTrackerDefaultThresholdDetectsAnyDifference() {
    let paneID = PaneID(rawValue: "%1")
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    #expect(tracker.observe(screen: "a\nb", paneID: paneID, at: now) == nil)
    #expect(tracker.observe(screen: "a\nB", paneID: paneID, at: now.advanced(by: .seconds(1))) == 0)
    #expect(
      tracker.observe(screen: "a\nB", paneID: paneID, at: now.advanced(by: .seconds(3))) == 2)
  }

  @Test("しきい値未満の変化では鮮度が 0 に戻らず、最後の変化からの経過が伸び続ける")
  func screenTrackerIgnoresChangesBelowThreshold() {
    let paneID = PaneID(rawValue: "%1")
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    // idle 真値区間で実際に観測されたステータス行の遷移 (Spikes/gate3/README.md §13.0)。
    // 毎回 1 行だけが違う。
    let statusLines = [
      "● high · /effort",
      "tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf and reattach"
        + " for focus tracking",
      "",
    ]
    var elapsed: [TimeInterval?] = []
    for (index, statusLine) in statusLines.enumerated() {
      elapsed.append(
        tracker.observe(
          screen: "❯ \n\n\(statusLine)", paneID: paneID,
          at: now.advanced(by: .seconds(index * 2)), minimumChangedLines: 2
        ))
    }
    #expect(elapsed == [nil, 2, 4])
  }

  @Test("しきい値以上の変化は出力として鮮度を 0 に戻す")
  func screenTrackerDetectsChangesAtThreshold() {
    let paneID = PaneID(rawValue: "%1")
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    _ = tracker.observe(screen: "a\nb\nc", paneID: paneID, at: now, minimumChangedLines: 2)
    let changed = tracker.observe(
      screen: "a\nB\nC", paneID: paneID, at: now.advanced(by: .seconds(2)), minimumChangedLines: 2)
    #expect(changed == 0)
  }

  @Test("比較対象は常に1回前の観測で、しきい値未満の変化は累積しない")
  func screenTrackerComparesAgainstPreviousObservation() {
    let paneID = PaneID(rawValue: "%1")
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    _ = tracker.observe(screen: "a\nb", paneID: paneID, at: now, minimumChangedLines: 2)
    // 1 行ずつ別の行が変わる。初回の画面と比べれば 2 行違うが、出力とはみなさない。
    _ = tracker.observe(
      screen: "A\nb", paneID: paneID, at: now.advanced(by: .seconds(2)), minimumChangedLines: 2)
    let elapsed = tracker.observe(
      screen: "A\nB", paneID: paneID, at: now.advanced(by: .seconds(4)), minimumChangedLines: 2)
    #expect(elapsed == 4)
  }

  @Test("行数の違う画面は短い側を空行で埋めて index 単位で数える")
  func screenTrackerPadsShorterScreen() {
    let paneID = PaneID(rawValue: "%1")
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    _ = tracker.observe(screen: "a", paneID: paneID, at: now, minimumChangedLines: 2)
    let elapsed = tracker.observe(
      screen: "a\nb", paneID: paneID, at: now.advanced(by: .seconds(2)), minimumChangedLines: 2)
    #expect(elapsed == 2)
    let changed = tracker.observe(
      screen: "a\nb\nc\nd", paneID: paneID, at: now.advanced(by: .seconds(4)),
      minimumChangedLines: 2)
    #expect(changed == 0)
  }

  @Test("0 以下のしきい値は 1 と同じに扱い、経過を常に 0 へ潰さない", arguments: [0, -1])
  func screenTrackerClampsNonPositiveThreshold(_ minimumChangedLines: Int) {
    let paneID = PaneID(rawValue: "%1")
    let now = ContinuousClock().now
    var tracker = AgentScreenChangeTracker()
    _ = tracker.observe(
      screen: "a\nb", paneID: paneID, at: now, minimumChangedLines: minimumChangedLines)
    let unchanged = tracker.observe(
      screen: "a\nb", paneID: paneID, at: now.advanced(by: .seconds(2)),
      minimumChangedLines: minimumChangedLines)
    let changed = tracker.observe(
      screen: "a\nB", paneID: paneID, at: now.advanced(by: .seconds(4)),
      minimumChangedLines: minimumChangedLines)
    #expect(unchanged == 2)
    #expect(changed == 0)
  }

  @Test("観測ループは Adapter が宣言したしきい値を信号源へ渡す")
  func observationsPassAdapterThresholdToSource() async {
    let source = ThresholdRecordingSignalSource()
    let stream = ClaudeCodeAdapter().observations(
      of: claudePane, from: source,
      intervals: AgentObservationIntervals(signals: .milliseconds(1), liveness: .milliseconds(1))
    )
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(await source.recordedMinimumChangedLines == [2])
  }

  @Test("画面活動のしきい値を宣言するのは Claude だけで、他の Adapter は既定の 1")
  func onlyClaudeRaisesScreenActivityThreshold() {
    #expect(ClaudeCodeAdapter().minimumChangedLinesForScreenActivity == 2)
    #expect(CodexAdapter().minimumChangedLinesForScreenActivity == 1)
    #expect(
      ProcessDetectionFallbackAdapter(processNames: ["agent"])
        .minimumChangedLinesForScreenActivity == 1)
  }

  private let claudePane = PaneSnapshot(
    id: PaneID(rawValue: "%1"), processID: 1, tty: "/dev/ttys001", currentCommand: "claude",
    currentPath: "/tmp", title: "", termination: nil
  )

  private func assertNeverError(_ result: AgentObservationResult, fixture: AgentStateFixture) {
    switch result {
    case .absent:
      #expect(fixture.acceptableStates.contains("absent"))
    case .observation(let observation):
      #expect(observation.state != .error)
      #expect(!fixture.acceptableStates.contains("absent"))
    }
  }
}

private enum ObservationFailure: Error {
  case failed
}

private actor KnownThenFailingSignalSource: AgentSignalSource {
  private var hasReturnedSignals = false

  func signals(
    for pane: PaneSnapshot, minimumChangedLines: Int
  ) async throws -> AgentSignals {
    guard !hasReturnedSignals else { throw ObservationFailure.failed }
    hasReturnedSignals = true
    return AgentSignals(
      paneTitle: "", screenText: "Claude Code v test\n❯ \nmanual mode on",
      secondsSinceScreenChange: 2, observedAt: Date(timeIntervalSince1970: 1)
    )
  }

  func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    .alive
  }
}

private actor ThresholdRecordingSignalSource: AgentSignalSource {
  private(set) var recordedMinimumChangedLines: [Int] = []

  func signals(
    for pane: PaneSnapshot, minimumChangedLines: Int
  ) async throws -> AgentSignals {
    recordedMinimumChangedLines.append(minimumChangedLines)
    return AgentSignals(
      paneTitle: "", screenText: "Claude Code v test\n❯ \nmanual mode on",
      secondsSinceScreenChange: 2, observedAt: Date(timeIntervalSince1970: 1)
    )
  }

  func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    .alive
  }
}
