import Foundation
import TerminalCore
import Testing

@Suite("Claude Code の API 失敗行")
struct ClaudeCodeAdapterErrorLineTests {
  @Test(
    "未ログインの文言が深い引用か後続の本文があれば Completed (Issue #725)",
    arguments: [("\n  ⎿ ", "\n    ⎿ "), ("\n✻ Brewed", "\n⏺ Done.\n✻ Brewed")]
  )
  func quotedOrSupersededLoginErrorIsCompleted(replacement: (String, String)) throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-error-not-logged-in").first)
    let screen = fixture.screen.replacingOccurrences(of: replacement.0, with: replacement.1)
    try #require(screen != fixture.screen)
    #expect(classifyQuietScreen(screen) == "completed")
  }

  @Test("未ログインの失敗画面に完了行が無ければ Error にしない (Issue #725)")
  func loginErrorWithoutDoneMarkerIsNotError() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-error-not-logged-in").first)
    let screen = fixture.screen.components(separatedBy: "\n")
      .filter { !$0.contains("· done") }
      .joined(separator: "\n")
    try #require(screen != fixture.screen)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) != "error")
  }

  private func classifyQuietScreen(_ screen: String) -> String {
    fixtureState(
      of: ClaudeCodeAdapter().classify(
        signals: AgentSignals(
          paneTitle: "", screenText: screen, styledScreenText: nil,
          secondsSinceScreenChange: 2.0, hasObservedScreenChange: true,
          observedAt: .distantPast
        ), liveness: .alive))
  }
}
