import TerminalCore
import Testing

@Suite("Claude Code の実測 fixture")
struct ClaudeCodeAdapterTests {
  @Test("全 fixture を列挙して許容状態へ分類する")
  func fixtures() throws {
    let adapter = ClaudeCodeAdapter()
    let fixtures = try AgentStateFixture.load(prefix: "claude-")
    #expect(fixtures.count == 8)
    for fixture in fixtures {
      let actual = fixtureState(
        of: adapter.classify(signals: fixture.signals, liveness: fixture.liveness)
      )
      #expect(fixture.acceptableStates.contains(actual), Comment(rawValue: fixture.source))
    }
  }

  @Test("permission 文言が変わっても残存 done を Completed と断言しない")
  func permissionMutationIsUnknown() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "claude-permission").first)
    let mutated = AgentSignals(
      paneTitle: fixture.paneTitle,
      screenText: fixture.screen
        .replacingOccurrences(of: "Do you want to ", with: "Confirm whether to ")
        .replacingOccurrences(of: "Esc to cancel · Tab to amend", with: "Escape cancels"),
      secondsSinceOutput: fixture.secondsSinceWindowActivity,
      isPaneInMode: fixture.paneInMode,
      observedAt: .distantPast
    )
    let result = ClaudeCodeAdapter().classify(signals: mutated, liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }
}
