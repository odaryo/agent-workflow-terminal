import Foundation
import TerminalCore
import Testing

@Suite("Claude Code の実測 fixture")
struct ClaudeCodeAdapterTests {
  @Test("全 fixture を列挙して許容状態へ分類する")
  func fixtures() throws {
    let adapter = ClaudeCodeAdapter()
    let fixtures = try AgentStateFixture.load(prefix: "claude-")
    #expect(fixtures.count == 24)
    for fixture in fixtures {
      let actual = fixtureState(
        of: adapter.classify(signals: fixture.signals, liveness: fixture.liveness)
      )
      #expect(fixture.acceptableStates.contains(actual), Comment(rawValue: fixture.source))
    }
  }

  @Test("送信済みプロンプトが画面外でも入力中は Unknown (Issue #382)")
  func longTurnWithTypedInputIsUnknown() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-completed-long-turn").first)
    let screen = fixture.screen.replacingOccurrences(
      of: "❯\u{00A0}\n", with: "❯\u{00A0}typed\n")
    try #require(screen != fixture.screen)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("送信済みプロンプトが画面外でも完了行より上の spinner を優先して Working (Issue #382)")
  func longTurnWithSpinnerAboveDoneMarkerIsWorking() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-completed-long-turn").first)
    let doneLine = "✻ Crunched for 2s · done 4:30 PM\n"
    let screen = fixture.screen.replacingOccurrences(
      of: doneLine, with: "✻ Propagating… (5s · ↓ 12 tokens)\n" + doneLine)
    try #require(screen != fixture.screen)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "working")
  }

  @Test(
    "§12.8 trust prompt は初回観測・画面変化直後もカーソル位置によらず Permission (Issue #252)",
    arguments: [nil, 0.0] as [TimeInterval?], [false, true]
  )
  func trustPromptIsPermission(elapsed: TimeInterval?, selectTrust: Bool) throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "claude-2.1.319-trust-prompt").first)
    var screen = fixture.screen
    if selectTrust {
      screen = screen.replacingOccurrences(of: " ❯ No, exit\n", with: "   No, exit\n")
      try #require(screen != fixture.screen)
      let selectedScreen = screen.replacingOccurrences(
        of: "   Yes, I trust this folder\n", with: " ❯ Yes, I trust this folder\n")
      try #require(selectedScreen != screen)
      screen = selectedScreen
    }
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: elapsed, hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) == "permission")
  }

  @Test("継続行が空白だけなら空の入力欄として Completed (Issue #270)")
  func whitespaceOnlyContinuationIsCompleted() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-typing-multiline-empty-first").first)
    let screen = fixture.screen.replacingOccurrences(of: "  second line\n", with: "  \n")
    try #require(screen != fixture.screen)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "completed")
  }

  @Test("先頭行が空でも3行の入力の途中は Unknown (Issue #270)")
  func threeLineInputWithEmptyFirstLineIsUnknown() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-typing-multiline-empty-first").first)
    let screen = fixture.screen.replacingOccurrences(
      of: "  second line\n", with: "  second line\n  third line\n")
    try #require(screen != fixture.screen)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("区切りが無ければ入力欄の先頭行だけで判定して Completed (Issue #270)")
  func multilineInputWithoutSeparatorsUsesFirstLine() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-typing-multiline-empty-first").first)
    let screen = fixture.screen.replacingOccurrences(
      of: "(?m)^─+\n", with: "", options: .regularExpression)
    try #require(screen != fixture.screen)
    try #require(!screen.contains("─"))
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: fixture.liveness)
    #expect(fixtureState(of: result) == "completed")
  }

  @Test("入力欄のサジェストが dim なら空欄として扱う")
  func dimPlaceholderCountsAsEmptyInputBox() throws {
    for prefix in ["claude-2.1.263-idle-placeholder", "claude-2.1.263-completed-placeholder"] {
      let fixture = try #require(AgentStateFixture.load(prefix: prefix).first)
      let actual = fixtureState(
        of: ClaudeCodeAdapter().classify(signals: fixture.signals, liveness: .alive))
      #expect(actual == fixture.expectedState, Comment(rawValue: prefix))
    }
  }

  @Test("属性が無ければ Idle / Completed へ丸めず、理由を screenAttributesUnavailable にする")
  func placeholderWithoutAttributesStaysUnknown() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.263-completed-placeholder").first)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: fixture.screen, styledScreenText: nil,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: .alive)
    guard case .observation(let observation) = result else {
      Issue.record("absent")
      return
    }
    #expect(observation.state == .unknown)
    #expect(observation.unknownReason == .screenAttributesUnavailable)
  }

  @Test("色の付かない捕捉では dim を根拠にしない")
  func captureWithoutAnyStylingStaysUnknown() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.263-completed-placeholder").first)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: fixture.screen,
        styledScreenText: fixture.screen,
        secondsSinceScreenChange: fixture.secondsSinceScreenChange, hasObservedScreenChange: true,
        observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("permission 文言が変わっても残存 done を Completed と断言しない")
  func permissionMutationIsUnknown() throws {
    func mutate(_ screen: String) -> String {
      screen
        .replacingOccurrences(of: "Do you want to ", with: "Confirm whether to ")
        .replacingOccurrences(of: "Esc to cancel · Tab to amend", with: "Escape cancels")
    }
    for prefix in ["claude-2.1.259-permission", "claude-2.1.263-permission"] {
      let fixture = try #require(AgentStateFixture.load(prefix: prefix).first)
      let mutated = AgentSignals(
        paneTitle: fixture.paneTitle,
        screenText: mutate(fixture.screen),
        styledScreenText: fixture.styledScreen.map(mutate),
        secondsSinceScreenChange: 2,
        hasObservedScreenChange: true, observedAt: .distantPast
      )
      let result = ClaudeCodeAdapter().classify(signals: mutated, liveness: .alive)
      #expect(fixtureState(of: result) == "unknown", Comment(rawValue: prefix))
    }
  }

  @Test("初回観測では残存完了マーカーを Completed と断言しない")
  func initialObservationIsNotCompleted() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "claude-2.1.259-completed").first)
    let signals = AgentSignals(
      paneTitle: fixture.paneTitle, screenText: fixture.screen, styledScreenText: nil,
      secondsSinceScreenChange: nil, hasObservedScreenChange: true, observedAt: .distantPast
    )
    let result = ClaudeCodeAdapter().classify(signals: signals, liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("前ターンの done が残るターン開始直後でも、画面が動いていれば Working")
  func turnStartWithStaleDoneMarkerIsWorking() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.259-working-turn-start").first)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: fixture.screen, styledScreenText: nil,
        secondsSinceScreenChange: 0, hasObservedScreenChange: true, observedAt: .distantPast
      ),
      liveness: .alive
    )
    // 残存 done は前ターンのものなので、画面鮮度が失われた場合の Completed の根拠にはしない。
    #expect(fixtureState(of: result) == "working")
  }

  @Test(
    "spinner 行があれば画面変化から2秒後も Working (Issue #627)",
    arguments: [
      "claude-2.1.319-working-tool-spinner",
      "claude-2.1.319-working-spinner-no-elapsed",
    ]
  )
  func spinnerWithQuietScreenIsWorking(prefix: String) throws {
    let fixture = try #require(AgentStateFixture.load(prefix: prefix).first)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: fixture.screen,
        styledScreenText: fixture.styledScreen, secondsSinceScreenChange: 2.0,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) == "working")
  }

  @Test(
    "spinner 行があっても初回観測は Unknown / signalMissing (Issue #627)",
    arguments: [
      "claude-2.1.319-working-tool-spinner",
      "claude-2.1.319-working-spinner-no-elapsed",
    ]
  )
  func spinnerOnInitialObservationIsSignalMissing(prefix: String) throws {
    let fixture = try #require(AgentStateFixture.load(prefix: prefix).first)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: fixture.screen,
        styledScreenText: fixture.styledScreen, secondsSinceScreenChange: nil,
        hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    guard case .observation(let observation) = result else {
      Issue.record("absent")
      return
    }
    #expect(observation.state == .unknown)
    #expect(observation.unknownReason == .signalMissing)
  }

  @Test("spinner 行が消えて前ターンの完了行だけが残れば Unknown (Issue #627)")
  func removedSpinnerWithStaleDoneMarkerIsUnknown() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-working-tool-spinner").first)
    let screen = fixture.screen.replacingOccurrences(
      of: "✻ Propagating… (5s · ↓ 12 tokens)\n", with: "")
    try #require(screen != fixture.screen)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: 2.0, hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("前ターンの done が残るターン開始画面は、2秒後も spinner 行で Working、消せば Unknown (Issue #627)")
  func quietTurnStartWithStaleDoneMarker() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.259-working-turn-start").first)
    func classify(_ screen: String) -> String {
      fixtureState(
        of: ClaudeCodeAdapter().classify(
          signals: AgentSignals(
            paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
            secondsSinceScreenChange: 2.0, hasObservedScreenChange: true,
            observedAt: .distantPast
          ), liveness: .alive))
    }
    let withoutSpinner = fixture.screen.replacingOccurrences(of: "✻ Meandering…\n", with: "")
    try #require(withoutSpinner != fixture.screen)
    #expect(classify(fixture.screen) == "working")
    #expect(classify(withoutSpinner) == "unknown")
  }

  @Test(
    "列0から始まらない行やツールの実行表示は spinner と見なさない (Issue #627)",
    arguments: ["  ✻ Propagating…", "⏺ Running 2 shell commands…"]
  )
  func spinnerLikeOutputIsUnknown(replacement: String) throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-working-tool-spinner").first)
    let screen = fixture.screen.replacingOccurrences(
      of: "✻ Propagating… (5s · ↓ 12 tokens)", with: replacement)
    try #require(screen != fixture.screen)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: 2.0, hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("最後の送信済みプロンプトより上にしか spinner 行が無ければ Unknown (Issue #627)")
  func spinnerAboveLastSubmittedPromptIsUnknown() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.319-working-tool-spinner").first)
    let spinner = "✻ Propagating… (5s · ↓ 12 tokens)\n"
    let withoutSpinner = fixture.screen.replacingOccurrences(of: spinner, with: "")
    try #require(withoutSpinner != fixture.screen)
    let submittedPrompt =
      "❯ Run the shell command: sleep 25 . After it finishes, reply with DONE only."
    let screen = withoutSpinner.replacingOccurrences(
      of: submittedPrompt, with: spinner + submittedPrompt)
    try #require(screen != withoutSpinner)
    let result = ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: screen, styledScreenText: nil,
        secondsSinceScreenChange: 2.0, hasObservedScreenChange: true, observedAt: .distantPast
      ), liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("画面変化から1.0秒までは Working、直後は Unknown")
  func workingThresholdBoundary() throws {
    let fixture = try #require(
      AgentStateFixture.load(prefix: "claude-2.1.259-working-streaming").first)
    func classify(elapsed: TimeInterval) -> String {
      fixtureState(
        of: ClaudeCodeAdapter().classify(
          signals: AgentSignals(
            paneTitle: fixture.paneTitle, screenText: fixture.screen, styledScreenText: nil,
            secondsSinceScreenChange: elapsed, hasObservedScreenChange: true,
            observedAt: .distantPast
          ),
          liveness: .alive
        ))
    }
    #expect(classify(elapsed: 1.0) == "working")
    #expect(classify(elapsed: 1.000_001) == "unknown")
    #expect(classify(elapsed: 1.5) == "unknown")
  }

  @Test("基準から1秒以内でも、画面の変化を観測していなければ Working にせず signalMissing (Issue #559)")
  func recentBaselineWithoutObservedChangeIsSignalMissing() throws {
    let result = try classifyIdleScreen(elapsed: 0.3, hasObservedScreenChange: false)
    guard case .observation(let observation) = result else {
      Issue.record("absent")
      return
    }
    #expect(observation.state == .unknown)
    #expect(observation.unknownReason == .signalMissing)
  }

  @Test("画面の変化を観測した後は、1秒以内なら Working (Issue #559)")
  func recentObservedChangeIsWorking() throws {
    let result = try classifyIdleScreen(elapsed: 0.3, hasObservedScreenChange: true)
    #expect(fixtureState(of: result) == "working")
  }

  @Test("変化を観測していなくても、しきい値を超えて静かなら起動バナーの空欄は Idle (Issue #559)")
  func quietBaselineWithoutObservedChangeIsIdle() throws {
    let result = try classifyIdleScreen(elapsed: 2.0, hasObservedScreenChange: false)
    #expect(fixtureState(of: result) == "idle")
  }

  /// 起動バナーと空の入力欄がある画面 (`claude-2.1.259-idle`) を、経過と変化の観測の有無だけ
  /// 差し替えて分類する。
  private func classifyIdleScreen(
    elapsed: TimeInterval, hasObservedScreenChange: Bool
  ) throws -> AgentObservationResult {
    let fixture = try #require(AgentStateFixture.load(prefix: "claude-2.1.259-idle").first)
    return ClaudeCodeAdapter().classify(
      signals: AgentSignals(
        paneTitle: fixture.paneTitle, screenText: fixture.screen,
        styledScreenText: fixture.styledScreen, secondsSinceScreenChange: elapsed,
        hasObservedScreenChange: hasObservedScreenChange, observedAt: .distantPast
      ),
      liveness: .alive
    )
  }
}
