import Foundation
import TerminalCore
import Testing

@Suite("Claude Code のスクロールと画面外プロンプト (Issue #653)")
struct ClaudeCodeAdapterScrollTests {
  @Test("スクロール中の前ターンの完了行は Completed / Idle にせず Unknown (Issue #653)")
  func scrolledRunningIsUnknown() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-scrolled-running").first)
    let result = ClaudeCodeAdapter().classify(signals: fixture.signals, liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("スクロール中の印の文字列だけを除くと従来どおり Completed (Issue #653)")
  func scrolledRunningWithoutIndicatorIsCompleted() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-scrolled-running").first)
    let indicator = "Jump to bottom: fn+↓ to scroll"
    let styled = try #require(fixture.styledScreen)
    try #require(fixture.screen.contains(indicator))
    try #require(styled.contains(indicator))
    let result = classify(
      fixture: fixture,
      screen: fixture.screen.replacingOccurrences(of: indicator, with: ""),
      styled: styled.replacingOccurrences(of: indicator, with: ""))
    #expect(fixtureState(of: result) == "completed")
  }

  @Test(
    "入力欄の上側区切り線の1〜3行前の印は、前後の空白と同じ行の本文長によらず Unknown (Issue #653)",
    arguments: [
      "Jump to bottom: fn+↓ to scroll",
      "  短い本文 Jump to bottom: fn+↓ to scroll   ",
      "       100111010と書かれます。さらに本文が続きます。 Jump to bottom: fn+↓ to scroll ",
    ], [0, 1, 2]
  )
  func scrollIndicatorNearInputSeparatorIsUnknown(indicatorLine: String, blankLines: Int) throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-scrolled-running").first)
    func moveIndicator(_ screen: String) throws -> String {
      var lines = screen.components(separatedBy: "\n")
      let index = try #require(lines.firstIndex { $0.contains("Jump to bottom: fn+↓ to scroll") })
      try #require(index + 1 < lines.count)
      try #require(lines[index + 1].isEmpty)
      lines.replaceSubrange(
        index...index + 1,
        with: [indicatorLine] + Array(repeating: "", count: blankLines))
      return lines.joined(separator: "\n")
    }
    let result = try classify(
      fixture: fixture, screen: moveIndicator(fixture.screen),
      styled: moveIndicator(#require(fixture.styledScreen)))
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("入力欄の区切り線から離れた会話本文の印はスクロール扱いせず Completed (Issue #653)")
  func scrollIndicatorInConversationBodyIsCompleted() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-scrolled-running").first)
    let indicator = "Jump to bottom: fn+↓ to scroll"
    func moveIndicatorToBody(_ screen: String) -> String {
      screen.replacingOccurrences(of: indicator, with: "")
        .replacingOccurrences(of: "300. 300は", with: "表示文言の例: \(indicator)\n  300. 300は")
    }
    let styled = try #require(fixture.styledScreen)
    try #require(fixture.screen.contains("300. 300は"))
    try #require(styled.contains("300. 300は"))
    let result = classify(
      fixture: fixture, screen: moveIndicatorToBody(fixture.screen),
      styled: moveIndicatorToBody(styled))
    #expect(fixtureState(of: result) == "completed")
  }

  @Test(
    "送信済みプロンプトが画面外の非 dim 入力は Unknown、dim サジェストは Completed (Issue #653)",
    arguments: [false, true]
  )
  func longTurnWithStyledInput(dim: Bool) throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-completed-long-turn").first)
    let originalStyled = try #require(fixture.styledScreen)
    let screen = fixture.screen.replacingOccurrences(of: "❯\u{00A0}\n", with: "❯\u{00A0}typed\n")
    let input = dim ? "\u{1b}[2mtyped\u{1b}[22m" : "typed"
    let styled = originalStyled.replacingOccurrences(
      of: "❯\u{00A0}\n", with: "❯\u{00A0}\(input)\n")
    try #require(screen != fixture.screen)
    try #require(styled != originalStyled)
    let parsed = StyledScreenText(capturedWithEscapeSequences: styled)
    try #require(parsed.plainText == screen)
    try #require(parsed.containsAnyStyling)
    let inputLine = try #require(parsed.lines.last { $0.text.hasPrefix("❯") })
    try #require(inputLine.text == "❯\u{00A0}typed")
    try #require(inputLine.isDim.suffix(5).allSatisfy { $0 == dim })
    try #require(!screen.contains("❯ "))
    let result = classify(fixture: fixture, screen: screen, styled: styled)
    #expect(fixtureState(of: result) == (dim ? "completed" : "unknown"))
    if !dim {
      guard case .observation(let observation) = result else {
        Issue.record("absent")
        return
      }
      #expect(observation.unknownReason == .adapterUndetermined)
    }
  }

  private func classify(
    fixture: AgentStateFixture, screen: String, styled: String
  ) -> AgentObservationResult {
    ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: styled,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: fixture.liveness)
  }
}
