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

  // Error は安全に再現できず、検出信号が実証されていない (Spikes/gate3/README.md §4.2)。
  @Test("fixture は実測できた7種類だけを固定する")
  func observedKinds() throws {
    let all = try AgentStateFixture.load(prefix: "")
    let kinds = Set(all.flatMap(\.acceptableStates))
    #expect(
      kinds == ["idle", "working", "permission", "question", "completed", "unknown", "absent"])
  }
}
