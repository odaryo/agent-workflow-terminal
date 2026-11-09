import TerminalCore
import Testing

@Suite("Codex の実測 fixture")
struct CodexAdapterTests {
  @Test("全 fixture を列挙して許容状態へ分類する")
  func fixtures() throws {
    let adapter = CodexAdapter()
    let fixtures = try AgentStateFixture.load(prefix: "codex-")
    #expect(fixtures.count == 14)
    for fixture in fixtures {
      let actual = fixtureState(
        of: adapter.classify(signals: fixture.signals, liveness: fixture.liveness)
      )
      #expect(fixture.acceptableStates.contains(actual), Comment(rawValue: fixture.source))
    }
  }

  @Test("§12.8 trust prompt は title の spinner より優先して Permission (Issue #252)")
  func trustPromptWithSpinnerTitleIsPermission() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "codex-0.166.0-trust-prompt.json").first)
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
    let fixture = try #require(
      AgentStateFixture.load(prefix: "codex-0.166.0-trust-prompt.json").first)
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

  @Test(
    "返答中の trust 文言2行だけでは元の状態を変えない (Issue #252)",
    arguments: ["codex-0.152.1-working", "codex-0.152.1-completed"]
  )
  func trustTextInResponsePreservesState(prefix: String) throws {
    let fixture = try #require(AgentStateFixture.load(prefix: prefix).first)
    let responseLine = "  3（さん）— 三角形の辺の数です。"
    let screen = fixture.screen.replacingOccurrences(
      of: responseLine,
      with: "Trust this folder?\n› 1. Trust and continue\n" + responseLine)
    try #require(screen != fixture.screen)
    try #require(!screen.contains("Folder access"))
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == fixture.expectedState)
  }

  @Test("応答中に trust 画面と footer を引用しても Completed (Issue #645)")
  func quotedTrustPromptInResponseIsCompleted() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "codex-0.152.1-completed").first)
    let responseLine = "• notes.txt を作成し、today と1行だけ書きました。"
    let quotedPrompt = """
      Folder access
      /private/tmp/sanitized
      › 1. Trust and continue
      2. Back to Agent Command Center
      enter continue · esc back
      """
    let screen = fixture.screen.replacingOccurrences(
      of: responseLine, with: quotedPrompt + "\n" + responseLine)
    try #require(screen != fixture.screen)
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "completed")
  }

  @Test("入力欄の trust 文言だけでは Permission にしない (Issue #252)")
  func trustTextInInputIsUnknown() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "codex-0.152.1-idle").first)
    try #require(fixture.expectedState == "idle")
    let inputLine = try #require(
      fixture.screen.split(separator: "\n").first { $0.contains("Ask Codex to do anything") })
    let screen = fixture.screen.replacingOccurrences(
      of: String(inputLine), with: "› Trust this folder?")
    try #require(screen != fixture.screen)
    try #require(!screen.contains("Ask Codex to do anything"))
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: fixture.liveness)
    // 元の expectedState は idle だが、その根拠の Ask Codex to do anything が消え、
    // spinner や完了の根拠もないため、置換後は unknown を期待する。
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("trust prompt は選択肢2を選んでも Permission (Issue #252)")
  func trustPromptWithSecondOptionSelectedIsPermission() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "codex-0.166.0-trust-prompt.json").first)
    let withoutFirstSelection = fixture.screen.replacingOccurrences(
      of: "› 1. Trust and continue", with: "  1. Trust and continue")
    try #require(withoutFirstSelection != fixture.screen)
    let screen = withoutFirstSelection.replacingOccurrences(
      of: "  2. Back to Agent Command Center", with: "› 2. Back to Agent Command Center")
    try #require(screen != withoutFirstSelection)
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "permission")
  }

  @Test("§12.8 応答中に更新の確認を引用しても Permission にしない (Issue #639)")
  func quotedUpdatePromptInResponseIsNotPermission() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "codex-0.166.0-quoted-trust-in-reply.json").first)
    let quotedTrustPrompt = """
        Folder access
        /private/tmp/sanitized
        › 1. Trust and continue
          2. Back to Agent Command Center

          enter continue · esc back
      """
    let quotedUpdatePrompt = """
        Update available · 0.166.0 → 0.167.0
        Release notes: https://github.com/openai/codex/releases/latest

        › 1. Update now (...)
          2. Skip
          3. Skip until next version

          enter continue · esc skip
      """
    let screen = fixture.screen.replacingOccurrences(
      of: quotedTrustPrompt, with: quotedUpdatePrompt)
    try #require(screen != fixture.screen)
    try #require(screen.contains("Worked for "))
    try #require(screen.contains("› Ask Codex to do anything"))
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) != "permission")
  }

  @Test("§12.8 更新の確認は選択肢2を選んでも Permission (Issue #639)")
  func updatePromptWithSecondOptionSelectedIsPermission() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "codex-0.166.0-update-prompt.json").first)
    let withoutFirstSelection = fixture.screen.replacingOccurrences(
      of: "› 1. Update now", with: "  1. Update now")
    try #require(withoutFirstSelection != fixture.screen)
    let screen = withoutFirstSelection.replacingOccurrences(
      of: "  2. Skip\n", with: "› 2. Skip\n")
    try #require(screen != withoutFirstSelection)
    let result = CodexAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "permission")
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
