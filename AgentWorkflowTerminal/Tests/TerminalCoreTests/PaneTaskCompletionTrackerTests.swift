import Foundation
import TerminalCore
import Testing

@Suite("タスク完了表示の解除 (設計書 §12.7)")
struct PaneTaskCompletionTrackerTests {
  private static let pane = PaneID(rawValue: "%1")
  private static let first = AgentStampedValue(
    agentProcessID: 42, text: "t1", turnStartedAt: Date(timeIntervalSince1970: 90))
  private static let second = AgentStampedValue(
    agentProcessID: 42, text: "t1", turnStartedAt: Date(timeIntervalSince1970: 110))

  @Test("解除の記憶が無い pane に有効な token があれば完了として扱う (再起動直後を含む)")
  func showsCompletionWithoutPriorMemory() {
    var tracker = CompletionObservationFixture()
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
  }

  @Test("Idle から Working に入ったら、以前に始まったターンの完了を解除する")
  func dismissesOnTransitionToWorking() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
    // 同じ開始時刻の完了は、Working を抜けても戻らない。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .completed,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
  }

  @Test("token が同じでも開始時刻が閾値より後なら新しい完了として再び表示する")
  func showsAgainWhenTurnStartChanges() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.second), agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.second))
  }

  @Test("Working の最中に書かれた token は、Working が続いていても解除しない")
  func keepsTokenWrittenDuringWorking() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .unset, agentState: .working,
      observedAt: Date(timeIntervalSince1970: 100))

    // ハーネスは自分のターンの中で完了を書くので、書かれた時点の pane はまだ Working である。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
    // 次のターンが始まったら解除する。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
  }

  @Test("応答終了 (Completed) から Working に入っても解除する")
  func dismissesOnTransitionFromCompleted() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .completed,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
  }

  @Test(
    "直前の既知の状態が応答終了でなければ、Working に入っても解除しない",
    arguments: [AgentState.question, .permission, .error, .unknown, nil])
  func keepsCompletionWhenResumingFromNonTurnEnd(previous: AgentState?) {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: previous,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
  }

  @Test("同じターンの許可待ちを挟んでも、ターン中に書かれた完了は解除しない")
  func keepsCompletionAcrossPermissionInTheSameTurn() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
      observedAt: Date(timeIntervalSince1970: 100))

    // ターンの中で新しい token を書き、許可待ちを経て同じターンを続け、応答を終える。
    let sequence: [(AgentState, PaneTaskCompletionDisplay)] = [
      (.working, .completed(Self.second)),
      (.permission, .completed(Self.second)),
      (.working, .completed(Self.second)),
      (.idle, .completed(Self.second)),
    ]
    for (state, expected) in sequence {
      #expect(
        tracker.update(
          paneID: Self.pane, completion: .accepted(Self.second), agentState: state,
          observedAt: Date(timeIntervalSince1970: 120))
          == expected)
    }
    // 次のターンに入ったら解除する。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.second), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 130))
        == .dismissed(Self.second))
  }

  @Test("観測を始めた時点で Working なら、直前が分からないので解除しない")
  func firstObservationInWorkingDoesNotDismiss() {
    var tracker = CompletionObservationFixture()
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
  }

  private static let unidentified: [PaneSummaryEntry<AgentStampedValue>] = [
    .discarded(.agentProcessUnobservable(written: 42)),
    .discarded(.agentProcessAmbiguous(written: 42, candidates: [42, 43])),
  ]

  @Test("Agent プロセスを特定できなかった回は、解除済みの記憶を上書きしない", arguments: unidentified)
  func unidentifiedRoundKeepsDismissal(unidentified: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))

    // 次のターンへの遷移を ps が読めない回に観測しても、解除済みの token を空で上書きしない。
    // 表示は直前のまま返す (completed → none → completed と揺れると完了通知が二重になる)。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: unidentified, agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
  }

  @Test("Agent プロセスを特定できない回の解除閾値で、次に読めた完了を判定する", arguments: unidentified)
  func unidentifiedRoundAdvancesThreshold(unidentified: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: Self.pane, completion: unidentified, agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
  }

  @Test("Agent プロセスを特定できなかった回が最初の観測なら、表示しない", arguments: unidentified)
  func unidentifiedFirstRoundShowsNothing(unidentified: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = CompletionObservationFixture()
    #expect(
      tracker.update(
        paneID: Self.pane, completion: unidentified, agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100)) == .none)
    // 表示が無い回でも応答終了の観測は記憶する。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
  }

  // MARK: - Unknown / 観測なしの回

  @Test("Claude Code の通常の流れ: 応答終了 → 次のプロンプト入力中 (Unknown) → Working で解除する")
  func dismissesWhenUserTypesNextPrompt() {
    var tracker = CompletionObservationFixture()
    // ハーネスは自分のターンの中で完了を書く。次のプロンプトを打っている間、ClaudeCodeAdapter は
    // Unknown を返す (fixture `claude-2.1.263-typed-not-dim.json`)。
    let sequence: [(AgentState, PaneTaskCompletionDisplay)] = [
      (.working, .completed(Self.first)),
      (.completed, .completed(Self.first)),
      (.unknown, .completed(Self.first)),
      (.working, .dismissed(Self.first)),
      (.completed, .dismissed(Self.first)),
    ]
    for (state, expected) in sequence {
      #expect(
        tracker.update(
          paneID: Self.pane, completion: .accepted(Self.first), agentState: state,
          observedAt: Date(timeIntervalSince1970: 120))
          == expected)
    }
  }

  @Test(
    "Unknown と観測なしの回は直前の既知の状態を保ち、応答終了からの遷移として解除する",
    arguments: [AgentState.idle, .completed], [AgentState.unknown, nil])
  func unknownRoundKeepsTurnEnd(turnEnd: AgentState, between: AgentState?) {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: turnEnd,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: between,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: between,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
  }

  @Test(
    "Unknown と観測なしの回を挟んでも、同じターンの続きは解除しない",
    arguments: [AgentState.question, .permission], [AgentState.unknown, nil])
  func unknownRoundKeepsInTurnState(inTurn: AgentState, between: AgentState?) {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: inTurn,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: between,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
  }

  @Test("同じ token 文字列でも別の Agent プロセスが書いたものは別の完了")
  func sameTokenFromAnotherProcessIsNew() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
      observedAt: Date(timeIntervalSince1970: 100))
    let restarted = AgentStampedValue(
      agentProcessID: 43, text: Self.first.text, turnStartedAt: Self.first.turnStartedAt)

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(restarted), agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(restarted))
  }

  @Test("受理されていない完了は表示しない")
  func ignoresDiscardedCompletion() {
    var tracker = CompletionObservationFixture()
    #expect(
      tracker.update(
        paneID: Self.pane,
        completion: .discarded(.agentProcessMismatch(written: 1, current: 42)),
        agentState: .idle, observedAt: Date(timeIntervalSince1970: 100)) == .none)
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .unset, agentState: nil,
        observedAt: Date(timeIntervalSince1970: 100)) == .none)
  }

  @Test("別 pane の Working は他の pane の完了を解除しない")
  func workingInAnotherPaneDoesNotDismiss() {
    var tracker = CompletionObservationFixture()
    let claudePane = PaneID(rawValue: "%1")
    let codexPane = PaneID(rawValue: "%2")
    let claudeDone = AgentStampedValue(
      agentProcessID: 100, text: "c1", turnStartedAt: Date(timeIntervalSince1970: 90))
    _ = tracker.update(
      paneID: claudePane, completion: .accepted(claudeDone), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))

    _ = tracker.update(
      paneID: codexPane, completion: .unset, agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))
    _ = tracker.update(
      paneID: codexPane, completion: .unset, agentState: .working,
      observedAt: Date(timeIntervalSince1970: 100))

    #expect(
      tracker.update(
        paneID: claudePane, completion: .accepted(claudeDone), agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(claudeDone))
  }

  @Test("forget した pane は解除の記憶を失う")
  func forgetDropsMemory() {
    var tracker = CompletionObservationFixture()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
      observedAt: Date(timeIntervalSince1970: 100))
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working,
        observedAt: Date(timeIntervalSince1970: 100))
        == .dismissed(Self.first))
    tracker.forget(paneID: Self.pane)

    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle,
        observedAt: Date(timeIntervalSince1970: 100))
        == .completed(Self.first))
  }
}
