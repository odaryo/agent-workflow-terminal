import Foundation
import TerminalCore
import Testing

@Suite("Claude Code の実測 fixture")
struct ClaudeCodeAdapterTests {
  @Test("全 fixture を列挙して許容状態へ分類する")
  func fixtures() throws {
    let adapter = ClaudeCodeAdapter()
    let fixtures = try AgentStateFixture.load(prefix: "claude-")
    #expect(fixtures.count == 14)
    for fixture in fixtures {
      let actual = fixtureState(
        of: adapter.classify(signals: fixture.signals, liveness: fixture.liveness)
      )
      #expect(fixture.acceptableStates.contains(actual), Comment(rawValue: fixture.source))
    }
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
    // 画面鮮度が失われたときにこの画面がどう転ぶかは固定しない。現状は残存 done が勝って
    // completed になるが、それは受け入れた残差 (§12.2) であって仕様ではない。
    #expect(fixtureState(of: result) == "working")
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
