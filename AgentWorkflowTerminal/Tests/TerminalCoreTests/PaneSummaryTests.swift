import Foundation
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

  @Test(
    "先頭の10進数と半角空白1個で PID と本文に分け、見える字形を持つ Cf も受理する",
    arguments: [
      ("4242 設計｜実装中", AgentStampedValue(agentProcessID: 4242, text: "設計｜実装中")),
      ("123 \u{6DD}", AgentStampedValue(agentProcessID: 123, text: "\u{6DD}")),
    ])
  func parsesAgentStampedValue(raw: String, expected: AgentStampedValue) {
    #expect(AgentStampedValue.parse(raw) == .value(expected))
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

  @Test(
    "PID の後ろが見えない scalar だけなら本文が空として棄却する (設計書 §12.7)",
    arguments: ["123 \u{FEFF}", "123 \u{3164}"])
  func rejectsInvisibleOnlyStampedText(raw: String) {
    #expect(AgentStampedValue.parse(raw) == .malformed(.emptyText))
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
      readings(status: "4242 実装中", completion: "4242 turn=1794130451048 1700000000"),
      agent: .notRunning)
    #expect(result.status == .discarded(.agentProcessNotRunning(written: 4242)))
    #expect(result.completion == .discarded(.agentProcessNotRunning(written: 4242)))
  }

  @Test("同じ深さに Agent プロセスが複数あれば推測で選ばず受理しない")
  func discardsWhenAgentProcessIsAmbiguous() {
    let result = summary(
      readings(status: "4242 実装中", completion: "4242 turn=1794130451048 t1"),
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

  @Test(
    "目的が見えない scalar だけなら空白として棄却する (設計書 §12.7)",
    arguments: ["\u{FEFF}", "\u{200B}", "\u{3164}", "\u{FE0F}", " \u{FEFF} "])
  func discardsInvisibleOnlyPurpose(raw: String) {
    #expect(summary(readings(purpose: raw)).purpose == .discarded(.malformed(.blank)))
  }

  @Test(
    "目的の U+2800・見える Cf・空白に続く結合文字・見える文字と書式文字の混在値はそのまま受理する (設計書 §12.7)",
    arguments: ["\u{2800}", "a\u{FEFF}", "\u{6DD}", " \u{301}"])
  func acceptsPurposeWithBraillePatternBlankOrVisibleContent(raw: String) {
    #expect(summary(readings(purpose: raw)).purpose == .accepted(raw))
  }

  // MARK: - タスク完了 (@awt_done)

  @Test("PID が一致したタスク完了は token ごと受理する")
  func acceptsCompletion() {
    let result = summary(readings(completion: "4242 turn=1794130451048 1700000000"))
    #expect(
      result.completion
        == .accepted(
          AgentStampedValue(
            agentProcessID: 4242, text: "1700000000",
            turnStartedAt: Date(timeIntervalSince1970: 1794130451.048))))
  }

  // MARK: - 別 pane で値が混ざらない

  @Test("Claude Code と Codex の別 pane では、各 pane の Agent が書いた値だけが通る")
  func doesNotMixValuesAcrossPanes() {
    let claudePane = PaneID(rawValue: "%1")
    let codexPane = PaneID(rawValue: "%2")
    let claude = summary(
      readings(status: "100 claude の現在地", completion: "100 turn=1794130451048 c1", purpose: "目的A"),
      agent: .identified(processID: 100), pane: claudePane)
    // codex の pane に、claude の PID で書かれた値が紛れ込んだ場合 (pane 取り違え)。
    let codex = summary(
      readings(status: "100 claude の現在地", completion: "200 turn=1794130451048 x1", purpose: "目的B"),
      agent: .identified(processID: 200), pane: codexPane)

    #expect(claude.paneID == claudePane)
    #expect(claude.status == .accepted("claude の現在地"))
    #expect(claude.purpose == .accepted("目的A"))
    #expect(codex.paneID == codexPane)
    #expect(codex.status == .discarded(.agentProcessMismatch(written: 100, current: 200)))
    #expect(
      codex.completion
        == .accepted(
          AgentStampedValue(
            agentProcessID: 200, text: "x1",
            turnStartedAt: Date(timeIntervalSince1970: 1794130451.048))))
    #expect(codex.purpose == .accepted("目的B"))
  }
}
