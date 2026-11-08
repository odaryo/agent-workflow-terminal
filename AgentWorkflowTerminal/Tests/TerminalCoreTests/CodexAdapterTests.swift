import TerminalCore
import Testing

@Suite("Codex の実測 fixture")
struct CodexAdapterTests {
  @Test("全 fixture を列挙して許容状態へ分類する")
  func fixtures() throws {
    let adapter = CodexAdapter()
    let fixtures = try AgentStateFixture.load(prefix: "codex-")
    #expect(fixtures.count == 9)
    for fixture in fixtures {
      let actual = fixtureState(
        of: adapter.classify(signals: fixture.signals, liveness: fixture.liveness)
      )
      #expect(fixture.acceptableStates.contains(actual), Comment(rawValue: fixture.source))
    }
  }

  @Test("§12.8 trust prompt は title の spinner より優先して Permission (Issue #252)")
  func trustPromptWithSpinnerTitleIsPermission() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "codex-0.166.0-trust-prompt").first)
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: "⠴ wx2", screenText: fixture.screen, styledScreenText: fixture.styledScreen,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) == "permission")
  }

  @Test("trust 文言が両方消えた画面は footer が残っても Permission にしない (Issue #252)")
  func removedTrustMarkersAreNotPermission() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "codex-0.166.0-trust-prompt").first)
    let withoutQuestion = fixture.screen.replacingOccurrences(of: "Trust this folder?", with: "")
    try #require(withoutQuestion != fixture.screen)
    let screen = withoutQuestion.replacingOccurrences(of: "› 1. Trust and continue", with: "")
    try #require(screen != withoutQuestion)
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) != "permission")
  }

  @Test("title 由来の操作待ち category を保つ")
  func titleAttention() {
    let signals = AgentSignals(
      paneTitle: "[ . ] Action Required | worktree", screenText: "stale", styledScreenText: nil,
      secondsSinceScreenChange: nil, hasObservedScreenChange: true, observedAt: .distantPast
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
