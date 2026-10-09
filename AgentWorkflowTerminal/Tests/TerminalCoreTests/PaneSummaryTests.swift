import TerminalCore
import Testing

@Suite("pane 概要のハーネス連携の解釈 (設計書 §12.7)")
struct PaneSummaryTests {

  // MARK: - Helpers

  private static let pane = PaneID(rawValue: "%1")

  private func readings(
    status: String = "", completion: String = "", purpose: String = ""
  ) -> PaneSummaryReadings {
    PaneSummaryReadings(
      status: .value(status), completion: .value(completion), purpose: .value(purpose))
  }

  private func summary(
    _ readings: PaneSummaryReadings, agent: PaneAgentProcess = .identified(processID: 4242),
    pane: PaneID = Self.pane
  ) -> PaneSummary {
    PaneSummary(paneID: pane, readings: readings, agentProcess: agent)
  }

  // MARK: - `<agent-pid> <text>` の parse

  @Test("先頭の10進数と半角空白1個で PID と本文に分ける")
  func parsesAgentStampedValue() {
    #expect(
      AgentStampedValue.parse("4242 設計｜実装中")
        == .value(AgentStampedValue(agentProcessID: 4242, text: "設計｜実装中")))
  }

  @Test("区切りは最初の半角空白1個だけで、残りは本文としてそのまま持つ")
  func keepsRemainderVerbatim() {
    #expect(
      AgentStampedValue.parse("7  前後に空白 ")
        == .value(AgentStampedValue(agentProcessID: 7, text: " 前後に空白 ")))
    #expect(
      AgentStampedValue.parse(#"7 a\b|c 8 d"#)
        == .value(AgentStampedValue(agentProcessID: 7, text: #"a\b|c 8 d"#)))
  }

  @Test("空文字は未設定 (tmux は未設定と空文字を区別しない)")
  func emptyIsUnset() {
    #expect(AgentStampedValue.parse("") == .unset)
  }

  @Test(
    "形式違反は理由付きで棄却する",
    arguments: [
      ("   ", PaneSummaryFormatViolation.blank),
      ("\u{3000}", .blank),
      ("phase 実装中", .missingAgentProcessID),
      (" 42 実装中", .missingAgentProcessID),
      ("-42 実装中", .missingAgentProcessID),
      ("４２ 全角数字", .missingAgentProcessID),
      ("42", .missingSeparator),
      ("42\t実装中", .missingSeparator),
      ("42x 実装中", .missingSeparator),
      ("0 実装中", .agentProcessIDOutOfRange),
      ("2147483648 実装中", .agentProcessIDOutOfRange),
      ("42 ", .emptyText),
      ("42    ", .emptyText),
      ("42 実装\n中", .containsLineBreakOrControlCharacter),
      ("42 実装\r中", .containsLineBreakOrControlCharacter),
      ("42 実装\t中", .containsLineBreakOrControlCharacter),
      ("42 \u{1B}[31m赤", .containsLineBreakOrControlCharacter),
      ("42 a\u{1F}b", .containsLineBreakOrControlCharacter),
      ("42 a\u{85}b", .containsLineBreakOrControlCharacter),
      ("42 a\u{2028}b", .containsLineBreakOrControlCharacter),
      ("42 a\u{2029}b", .containsLineBreakOrControlCharacter),
    ])
  func rejectsMalformedValue(raw: String, violation: PaneSummaryFormatViolation) {
    #expect(AgentStampedValue.parse(raw) == .malformed(violation))
  }

  // MARK: - 現在地 (@awt_status) と PID 照合

  @Test("現在の Agent プロセスの PID と一致した現在地だけを受理する")
  func acceptsStatusFromCurrentAgent() {
    let result = summary(readings(status: "4242 設計｜相談中"))
    #expect(result.status == .accepted("設計｜相談中"))
  }

  @Test("PID が一致しない現在地は古い信号として捨てる")
  func discardsStatusFromOtherProcess() {
    let result = summary(readings(status: "1111 前の Agent の現在地"))
    #expect(result.status == .discarded(.agentProcessMismatch(written: 1111, current: 4242)))
    #expect(result.status.value == nil)
  }

  @Test("pane に Agent プロセスが居なければ現在地もタスク完了も受理しない")
  func discardsWhenNoAgentProcess() {
    let result = summary(
      readings(status: "4242 実装中", completion: "4242 1700000000"), agent: .notRunning)
    #expect(result.status == .discarded(.agentProcessNotRunning(written: 4242)))
    #expect(result.completion == .discarded(.agentProcessNotRunning(written: 4242)))
  }

  @Test("同じ深さに Agent プロセスが複数あれば推測で選ばず受理しない")
  func discardsWhenAgentProcessIsAmbiguous() {
    let result = summary(
      readings(status: "4242 実装中", completion: "4242 t1"),
      agent: .ambiguous(processIDs: [4242, 4343]))
    #expect(
      result.status
        == .discarded(.agentProcessAmbiguous(written: 4242, candidates: [4242, 4343])))
    #expect(
      result.completion
        == .discarded(.agentProcessAmbiguous(written: 4242, candidates: [4242, 4343])))
  }

  @Test("プロセス表を読めなかったときは受理しない")
  func discardsWhenAgentProcessIsUnobservable() {
    let result = summary(readings(status: "4242 実装中"), agent: .unobservable)
    #expect(result.status == .discarded(.agentProcessUnobservable(written: 4242)))
  }

  @Test("形式違反は PID 照合より先に理由として残す")
  func reportsFormatViolationBeforeProcessCheck() {
    let result = summary(readings(status: "実装中"), agent: .notRunning)
    #expect(result.status == .discarded(.malformed(.missingAgentProcessID)))
  }

  @Test("読めなかった値は読めなかった理由のまま残す")
  func keepsUnreadableReason() {
    let result = summary(
      PaneSummaryReadings(
        status: .unreadable(.containsLineBreakOrUnitSeparator),
        completion: .unreadable(.tooLong),
        purpose: .unreadable(.invalidUTF8)))
    #expect(result.status == .discarded(.unreadable(.containsLineBreakOrUnitSeparator)))
    #expect(result.completion == .discarded(.unreadable(.tooLong)))
    #expect(result.purpose == .discarded(.unreadable(.invalidUTF8)))
  }

  @Test("空の現在地は未設定")
  func emptyStatusIsUnset() {
    #expect(summary(readings()).status == .unset)
  }

  // MARK: - 目的 (@awt_purpose)

  @Test("目的は PID 照合をせずに受理する")
  func acceptsPurposeWithoutProcessCheck() {
    for agent in [
      PaneAgentProcess.notRunning, .unobservable, .ambiguous(processIDs: [1, 2]),
      .identified(processID: 9),
    ] {
      let result = summary(readings(purpose: "ログイン不具合を修正する"), agent: agent)
      #expect(result.purpose == .accepted("ログイン不具合を修正する"))
    }
  }

  @Test("PID の形をした目的も本文としてそのまま持つ")
  func purposeIsNotParsedAsStampedValue() {
    #expect(summary(readings(purpose: "4242 修正")).purpose == .accepted("4242 修正"))
  }

  @Test(
    "目的の空・空白のみ・制御文字",
    arguments: [
      ("", PaneSummaryEntry<String>.unset),
      ("  ", .discarded(.malformed(.blank))),
      ("1行目\n2行目", .discarded(.malformed(.containsLineBreakOrControlCharacter))),
      ("1行目\u{2028}2行目", .discarded(.malformed(.containsLineBreakOrControlCharacter))),
    ])
  func purposeEdgeCases(raw: String, expected: PaneSummaryEntry<String>) {
    #expect(summary(readings(purpose: raw)).purpose == expected)
  }

  // MARK: - タスク完了 (@awt_done)

  @Test("PID が一致したタスク完了は token ごと受理する")
  func acceptsCompletion() {
    let result = summary(readings(completion: "4242 1700000000"))
    #expect(
      result.completion
        == .accepted(AgentStampedValue(agentProcessID: 4242, text: "1700000000")))
  }

  // MARK: - 別 pane で値が混ざらない

  @Test("Claude Code と Codex の別 pane では、各 pane の Agent が書いた値だけが通る")
  func doesNotMixValuesAcrossPanes() {
    let claudePane = PaneID(rawValue: "%1")
    let codexPane = PaneID(rawValue: "%2")
    let claude = summary(
      readings(status: "100 claude の現在地", completion: "100 c1", purpose: "目的A"),
      agent: .identified(processID: 100), pane: claudePane)
    // codex の pane に、claude の PID で書かれた値が紛れ込んだ場合 (pane 取り違え)。
    let codex = summary(
      readings(status: "100 claude の現在地", completion: "200 x1", purpose: "目的B"),
      agent: .identified(processID: 200), pane: codexPane)

    #expect(claude.paneID == claudePane)
    #expect(claude.status == .accepted("claude の現在地"))
    #expect(claude.purpose == .accepted("目的A"))
    #expect(codex.paneID == codexPane)
    #expect(codex.status == .discarded(.agentProcessMismatch(written: 100, current: 200)))
    #expect(codex.completion == .accepted(AgentStampedValue(agentProcessID: 200, text: "x1")))
    #expect(codex.purpose == .accepted("目的B"))
  }
}

@Suite("タスク完了表示の解除 (設計書 §12.7)")
struct PaneTaskCompletionTrackerTests {
  private static let pane = PaneID(rawValue: "%1")
  private static let first = AgentStampedValue(agentProcessID: 42, text: "t1")
  private static let second = AgentStampedValue(agentProcessID: 42, text: "t2")

  @Test("解除の記憶が無い pane に有効な token があれば完了として扱う (再起動直後を含む)")
  func showsCompletionWithoutPriorMemory() {
    var tracker = PaneTaskCompletionTracker()
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
        == .completed(Self.first))
  }

  @Test("Idle から Working に入ったら、その時点の token の完了を解除する")
  func dismissesOnTransitionToWorking() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
    // token が変わるまで解除済みのまま。Working を抜けても戻らない。
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
        == .dismissed(Self.first))
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .completed)
        == .dismissed(Self.first))
  }

  @Test("token が変われば新しい完了として再び表示する")
  func showsAgainWhenTokenChanges() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.second), agentState: .idle)
        == .completed(Self.second))
  }

  @Test("Working の最中に書かれた token は、Working が続いていても解除しない")
  func keepsTokenWrittenDuringWorking() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .unset, agentState: .working)

    // ハーネスは自分のターンの中で完了を書くので、書かれた時点の pane はまだ Working である。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
        == .completed(Self.first))
    // 次のターンが始まったら解除する。
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
  }

  @Test("応答終了 (Completed) から Working に入っても解除する")
  func dismissesOnTransitionFromCompleted() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .completed)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
  }

  @Test(
    "直前の既知の状態が応答終了でなければ、Working に入っても解除しない",
    arguments: [AgentState.question, .permission, .error, .unknown, nil])
  func keepsCompletionWhenResumingFromNonTurnEnd(previous: AgentState?) {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: previous)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
  }

  @Test("同じターンの許可待ちを挟んでも、ターン中に書かれた完了は解除しない")
  func keepsCompletionAcrossPermissionInTheSameTurn() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)

    // ターンの中で新しい token を書き、許可待ちを経て同じターンを続け、応答を終える。
    let sequence: [(AgentState, PaneTaskCompletionDisplay)] = [
      (.working, .completed(Self.second)),
      (.permission, .completed(Self.second)),
      (.working, .completed(Self.second)),
      (.idle, .completed(Self.second)),
    ]
    for (state, expected) in sequence {
      #expect(
        tracker.update(paneID: Self.pane, completion: .accepted(Self.second), agentState: state)
          == expected)
    }
    // 次のターンに入ったら解除する。
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.second), agentState: .working)
        == .dismissed(Self.second))
  }

  @Test("観測を始めた時点で Working なら、直前が分からないので解除しない")
  func firstObservationInWorkingDoesNotDismiss() {
    var tracker = PaneTaskCompletionTracker()
    #expect(
      tracker.update(
        paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
  }

  private static let unidentified: [PaneSummaryEntry<AgentStampedValue>] = [
    .discarded(.agentProcessUnobservable(written: 42)),
    .discarded(.agentProcessAmbiguous(written: 42, candidates: [42, 43])),
  ]

  @Test("Agent プロセスを特定できなかった回は、解除済みの記憶を上書きしない", arguments: unidentified)
  func unidentifiedRoundKeepsDismissal(unidentified: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)

    // 次のターンへの遷移を ps が読めない回に観測しても、解除済みの token を空で上書きしない。
    // 表示は直前のまま返す (completed → none → completed と揺れると完了通知が二重になる)。
    #expect(
      tracker.update(paneID: Self.pane, completion: unidentified, agentState: .working)
        == .dismissed(Self.first))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
  }

  @Test("Agent プロセスを特定できなかった回に起きた遷移は、次に特定できた回で解除する", arguments: unidentified)
  func unidentifiedRoundDefersTransition(unidentified: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)

    #expect(
      tracker.update(paneID: Self.pane, completion: unidentified, agentState: .working)
        == .completed(Self.first))
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
  }

  @Test("Agent プロセスを特定できなかった回が最初の観測なら、表示しない", arguments: unidentified)
  func unidentifiedFirstRoundShowsNothing(unidentified: PaneSummaryEntry<AgentStampedValue>) {
    var tracker = PaneTaskCompletionTracker()
    #expect(tracker.update(paneID: Self.pane, completion: unidentified, agentState: .idle) == .none)
    // 特定できなかった回は記憶を進めないので、次の回が最初の観測と同じに扱われる。
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
  }

  // MARK: - Unknown / 観測なしの回

  @Test("Claude Code の通常の流れ: 応答終了 → 次のプロンプト入力中 (Unknown) → Working で解除する")
  func dismissesWhenUserTypesNextPrompt() {
    var tracker = PaneTaskCompletionTracker()
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
        tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: state)
          == expected)
    }
  }

  @Test(
    "Unknown と観測なしの回は直前の既知の状態を保ち、応答終了からの遷移として解除する",
    arguments: [AgentState.idle, .completed], [AgentState.unknown, nil])
  func unknownRoundKeepsTurnEnd(turnEnd: AgentState, between: AgentState?) {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: turnEnd)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: between)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: between)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
  }

  @Test(
    "Unknown と観測なしの回を挟んでも、同じターンの続きは解除しない",
    arguments: [AgentState.question, .permission], [AgentState.unknown, nil])
  func unknownRoundKeepsInTurnState(inTurn: AgentState, between: AgentState?) {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: inTurn)
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: between)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .completed(Self.first))
  }

  @Test("同じ token 文字列でも別の Agent プロセスが書いたものは別の完了")
  func sameTokenFromAnotherProcessIsNew() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(
      paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
    let restarted = AgentStampedValue(agentProcessID: 43, text: Self.first.text)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(restarted), agentState: .idle)
        == .completed(restarted))
  }

  @Test("受理されていない完了は表示しない")
  func ignoresDiscardedCompletion() {
    var tracker = PaneTaskCompletionTracker()
    #expect(
      tracker.update(
        paneID: Self.pane,
        completion: .discarded(.agentProcessMismatch(written: 1, current: 42)),
        agentState: .idle) == .none)
    #expect(tracker.update(paneID: Self.pane, completion: .unset, agentState: nil) == .none)
  }

  @Test("別 pane の Working は他の pane の完了を解除しない")
  func workingInAnotherPaneDoesNotDismiss() {
    var tracker = PaneTaskCompletionTracker()
    let claudePane = PaneID(rawValue: "%1")
    let codexPane = PaneID(rawValue: "%2")
    let claudeDone = AgentStampedValue(agentProcessID: 100, text: "c1")
    _ = tracker.update(paneID: claudePane, completion: .accepted(claudeDone), agentState: .idle)

    _ = tracker.update(paneID: codexPane, completion: .unset, agentState: .idle)
    _ = tracker.update(paneID: codexPane, completion: .unset, agentState: .working)

    #expect(
      tracker.update(paneID: claudePane, completion: .accepted(claudeDone), agentState: .idle)
        == .completed(claudeDone))
  }

  @Test("forget した pane は解除の記憶を失う")
  func forgetDropsMemory() {
    var tracker = PaneTaskCompletionTracker()
    _ = tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .working)
        == .dismissed(Self.first))
    tracker.forget(paneID: Self.pane)

    #expect(
      tracker.update(paneID: Self.pane, completion: .accepted(Self.first), agentState: .idle)
        == .completed(Self.first))
  }
}
