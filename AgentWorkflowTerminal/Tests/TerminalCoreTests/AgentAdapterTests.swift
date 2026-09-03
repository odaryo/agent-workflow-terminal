import Foundation
import TerminalCore
import Testing

@Suite("Agent Adapter の共通不変条件")
struct AgentAdapterTests {
  private let signals = AgentSignals(
    paneTitle: "Action Required",
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

  @Test("種別不明の操作待ちは Unknown のまま Needs Attention に分類する")
  func unspecifiedAttention() throws {
    let result = CodexAdapter().classify(signals: signals, liveness: .alive)
    guard case .observation(let observation) = result else {
      Issue.record("状態観測が必要")
      return
    }
    #expect(observation.state == .unknown)
    #expect(observation.category == .needsAttention)
    #expect(observation.unknownReason == .adapterUndetermined)
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
}
