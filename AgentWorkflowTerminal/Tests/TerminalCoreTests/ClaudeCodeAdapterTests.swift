import Foundation
import TerminalCore
import Testing

@Suite("Claude Code の実測 fixture")
struct ClaudeCodeAdapterTests {
  @Test("全 fixture を列挙して許容状態へ分類する")
  func fixtures() throws {
    let adapter = ClaudeCodeAdapter()
    let fixtures = try AgentStateFixture.load(prefix: "claude-")
    #expect(fixtures.count == 9)
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
      secondsSinceScreenChange: 2,
      observedAt: .distantPast
    )
    let result = ClaudeCodeAdapter().classify(signals: mutated, liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("初回観測では残存完了マーカーを Completed と断言しない")
  func initialObservationIsNotCompleted() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "claude-completed").first)
    let signals = AgentSignals(
      paneTitle: fixture.paneTitle, screenText: fixture.screen,
      secondsSinceScreenChange: nil, observedAt: .distantPast
    )
    let result = ClaudeCodeAdapter().classify(signals: signals, liveness: .alive)
    #expect(fixtureState(of: result) == "unknown")
  }

  @Test("前ターンの done が残るターン開始直後でも、画面が動いていれば Working")
  func turnStartWithStaleDoneMarkerIsWorking() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "claude-working-turn-start").first)
    func classify(elapsed: TimeInterval) -> String {
      fixtureState(
        of: ClaudeCodeAdapter().classify(
          signals: AgentSignals(
            paneTitle: fixture.paneTitle, screenText: fixture.screen,
            secondsSinceScreenChange: elapsed, observedAt: .distantPast
          ),
          liveness: .alive
        ))
    }
    #expect(classify(elapsed: 0) == "working")
    // 画面鮮度が失われると残存 done が勝つ。製品の 2.0 秒 polling で working 区間の
    // 0.45% (443 中 2 フレーム) がこれに当たる — 許容する残差 (§12.2)。
    #expect(classify(elapsed: 2.0) == "completed")
  }

  @Test("画面変化から1.0秒までは Working、直後は Unknown")
  func workingThresholdBoundary() throws {
    let fixture = try #require(AgentStateFixture.load(prefix: "claude-working-streaming").first)
    func classify(elapsed: TimeInterval) -> String {
      fixtureState(
        of: ClaudeCodeAdapter().classify(
          signals: AgentSignals(
            paneTitle: fixture.paneTitle, screenText: fixture.screen,
            secondsSinceScreenChange: elapsed, observedAt: .distantPast
          ),
          liveness: .alive
        ))
    }
    #expect(classify(elapsed: 1.0) == "working")
    #expect(classify(elapsed: 1.000_001) == "unknown")
    #expect(classify(elapsed: 1.5) == "unknown")
  }
}
