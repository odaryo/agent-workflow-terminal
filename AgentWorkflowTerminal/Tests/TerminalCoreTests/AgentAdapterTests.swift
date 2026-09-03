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
      observedAt: Date(timeIntervalSince1970: 1), category: .needsAttention
    )
    let representative = resolveWorktreeRepresentativeState(panes: [
      PaneAgentState(
        id: PaneID(rawValue: "%1"), observation: observation,
        lastUpdatedAt: Date(timeIntervalSince1970: 1)
      )
    ])
    #expect(representative?.category == .needsAttention)
    #expect(representative?.state == .unknown)
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

  func signals(for pane: PaneSnapshot) async throws -> AgentSignals {
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
