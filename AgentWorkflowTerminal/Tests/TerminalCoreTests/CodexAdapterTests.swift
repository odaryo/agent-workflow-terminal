import TerminalCore
import Testing

@Suite("Codex の実測 fixture")
struct CodexAdapterTests {
  @Test("全 fixture を列挙して許容状態へ分類する")
  func fixtures() throws {
    let adapter = CodexAdapter()
    let fixtures = try AgentStateFixture.load(prefix: "codex-")
    #expect(fixtures.count == 7)
    for fixture in fixtures {
      let actual = fixtureState(
        of: adapter.classify(signals: fixture.signals, liveness: fixture.liveness)
      )
      #expect(fixture.acceptableStates.contains(actual), Comment(rawValue: fixture.source))
    }
  }

  @Test("title 由来の操作待ち category を保つ")
  func titleAttention() {
    let signals = AgentSignals(
      paneTitle: "[ . ] Action Required | worktree", screenText: "stale",
      secondsSinceScreenChange: nil, observedAt: .distantPast
    )
    guard
      case .observation(let observation) = CodexAdapter().classify(
        signals: signals, liveness: .alive
      )
    else {
      Issue.record("状態観測が必要")
      return
    }
    #expect(observation.state == .unknown)
    #expect(observation.category == .needsAttention)
  }
}
