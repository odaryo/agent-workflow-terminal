import Foundation
import TerminalCore
import Testing

@Suite("Agent Adapter の共通不変条件")
struct AgentAdapterTests {
  private let signals = AgentSignals(
    paneTitle: "",
    screenText: "stale screen",
    secondsSinceOutput: 0,
    isPaneInMode: false,
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
      #expect(observationState(result) != .error)
    }
    for fixture in try AgentStateFixture.load(prefix: "codex-") {
      let result = CodexAdapter().classify(
        signals: fixture.signals, liveness: fixture.liveness
      )
      #expect(observationState(result) != .error)
    }
  }

  @Test("観測の Needs Attention category を代表状態まで保つ")
  func preservesObservationCategory() {
    let representative = resolveWorktreeRepresentativeState(panes: [
      PaneAgentState(
        id: PaneID(rawValue: "%1"), state: .unknown,
        lastUpdatedAt: Date(timeIntervalSince1970: 1), category: .needsAttention
      )
    ])
    #expect(representative?.category == .needsAttention)
    #expect(representative?.state == .unknown)
  }

  @Test("diagnostics が変わっても同じ Unknown 状態を再配信しない")
  func diagnosticsDoNotDriveEvents() async {
    let pane = PaneSnapshot(
      id: PaneID(rawValue: "%1"), processID: 1, tty: "", currentCommand: "",
      currentPath: "", title: "", termination: nil
    )
    let stream = ClaudeCodeAdapter().observations(
      of: pane, from: ChangingErrorSignalSource(),
      intervals: AgentObservationIntervals(
        signals: .milliseconds(1), liveness: .seconds(1)
      )
    )
    let consumer = Task {
      var count = 0
      for await _ in stream { count += 1 }
      return count
    }
    try? await Task.sleep(for: .milliseconds(30))
    consumer.cancel()
    #expect(await consumer.value == 1)
  }

  private func observationState(_ result: AgentObservationResult) -> AgentState? {
    guard case .observation(let observation) = result else { return nil }
    return observation.state
  }
}

private enum ChangingObservationError: Error {
  case sequence(Int)
}

private actor ChangingErrorSignalSource: AgentSignalSource {
  private var sequence = 0

  func signals(for pane: PaneSnapshot) async throws -> AgentSignals {
    sequence += 1
    throw ChangingObservationError.sequence(sequence)
  }

  func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    .alive
  }
}
