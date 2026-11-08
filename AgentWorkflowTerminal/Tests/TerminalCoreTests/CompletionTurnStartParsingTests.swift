import Foundation
import TerminalCore
import Testing

@Suite("完了のターン開始時刻の解釈 (設計書 §12.7)")
struct CompletionTurnStartParsingTests {
  private static let startedAt = Date(timeIntervalSince1970: 1794130451.048)

  @Test("turn= のエポックミリ秒を読み、token 本文の空白をそのまま保つ")
  func parsesCompletion() {
    #expect(
      AgentStampedValue.parseCompletion("42 turn=1794130451048 token 本文")
        == .value(
          AgentStampedValue(agentProcessID: 42, text: "token 本文", turnStartedAt: Self.startedAt)))
    #expect(
      AgentStampedValue.parseCompletion("42 turn=1794130451048  token 本文 ")
        == .value(
          AgentStampedValue(agentProcessID: 42, text: " token 本文 ", turnStartedAt: Self.startedAt)))
  }

  @Test("空文字は未設定")
  func emptyIsUnset() {
    #expect(AgentStampedValue.parseCompletion("") == .unset)
  }

  @Test("現在地の parse と既存の初期化では開始時刻は nil")
  func statusHasNoTurnStart() {
    let value = AgentStampedValue(agentProcessID: 42, text: "turn=1794130451048 token")
    #expect(value.turnStartedAt == nil)
    #expect(AgentStampedValue.parse("42 turn=1794130451048 token") == .value(value))
  }

  @Test(
    "turn= の印が無い旧形式は、数字の token も開始時刻として読まず拒否する",
    arguments: ["42 token", "42 1794130451048 token"])
  func rejectsLegacyCompletion(raw: String) {
    #expect(AgentStampedValue.parseCompletion(raw) == .malformed(.missingTurnStart))
  }

  @Test(
    "開始時刻の空・非数・0・範囲外は理由付きで拒否する",
    arguments: [
      "", "abc", "0", "-1", "1.5", "+123", "１２３", "1e3",
      "99999999999999999999999999999999999999999999999999",
    ])
  func rejectsInvalidTurnStart(milliseconds: String) {
    #expect(
      AgentStampedValue.parseCompletion("42 turn=\(milliseconds) token")
        == .malformed(.invalidTurnStart))
  }

  @Test(
    "開始時刻と token の間には半角空白が必要",
    arguments: ["42 turn=123", "42 turn=123token", "42 turn=123\ttoken"])
  func rejectsMissingTokenSeparator(raw: String) {
    guard case .malformed = AgentStampedValue.parseCompletion(raw) else {
      Issue.record("token の区切りが無い値を受理した: \(raw)")
      return
    }
  }

  @Test(
    "PID の検査は現在地と同じ理由で拒否する",
    arguments: [
      ("   ", PaneSummaryFormatViolation.blank),
      ("\u{3000}", .blank),
      ("phase turn=123 token", .missingAgentProcessID),
      (" 42 turn=123 token", .missingAgentProcessID),
      ("-42 turn=123 token", .missingAgentProcessID),
      ("４２ turn=123 token", .missingAgentProcessID),
      ("42", .missingSeparator),
      ("42\tturn=123 token", .missingSeparator),
      ("42x turn=123 token", .missingSeparator),
      ("0 turn=123 token", .agentProcessIDOutOfRange),
      ("2147483648 turn=123 token", .agentProcessIDOutOfRange),
    ])
  func rejectsInvalidPID(raw: String, violation: PaneSummaryFormatViolation) {
    #expect(AgentStampedValue.parseCompletion(raw) == .malformed(violation))
  }

  @Test(
    "token 本文の検査は現在地と同じで、見えない本文や制御文字を拒否する",
    arguments: [
      ("", PaneSummaryFormatViolation.emptyText), ("   ", .emptyText),
      ("\u{FEFF}", .emptyText), ("\u{3164}", .emptyText),
      ("a\nb", .containsLineBreakOrControlCharacter),
      ("a\rb", .containsLineBreakOrControlCharacter),
      ("a\tb", .containsLineBreakOrControlCharacter),
      ("\u{1B}[31mred", .containsLineBreakOrControlCharacter),
      ("a\u{1F}b", .containsLineBreakOrControlCharacter),
      ("a\u{85}b", .containsLineBreakOrControlCharacter),
      ("a\u{2028}b", .containsLineBreakOrControlCharacter),
      ("a\u{2029}b", .containsLineBreakOrControlCharacter),
    ])
  func rejectsInvalidToken(text: String, violation: PaneSummaryFormatViolation) {
    #expect(
      AgentStampedValue.parseCompletion("42 turn=123 \(text)") == .malformed(violation))
  }

  @Test("見える Cf は完了本文でも受理する")
  func acceptsVisibleFormatCharacter() {
    #expect(
      AgentStampedValue.parseCompletion("42 turn=1794130451048 \u{6DD}")
        == .value(
          AgentStampedValue(agentProcessID: 42, text: "\u{6DD}", turnStartedAt: Self.startedAt)))
  }

  @Test("PaneSummary は完了だけを新形式で読み、現在地は turn= も本文として保つ")
  func summaryUsesSeparateParsers() {
    let summary = summary(completion: "42 turn=1794130451048 token 本文")
    #expect(summary.status == .accepted("turn=1794130451048 現在地"))
    #expect(
      summary.completion
        == .accepted(
          AgentStampedValue(agentProcessID: 42, text: "token 本文", turnStartedAt: Self.startedAt)))
    #expect(self.summary(completion: "").completion == .unset)
  }

  @Test(
    "PaneSummary は旧形式の形式違反を PID 照合より先に残す",
    arguments: ["42 token", "42 1794130451048 token"])
  func summaryRejectsLegacyCompletion(raw: String) {
    #expect(
      summary(completion: raw, agent: .notRunning).completion
        == .discarded(.malformed(.missingTurnStart)))
  }

  private func summary(
    completion: String, agent: PaneAgentProcess = .identified(processID: 42)
  ) -> PaneSummary {
    PaneSummary(
      paneID: PaneID(rawValue: "%1"),
      readings: PaneSummaryReadings(
        status: .value("42 turn=1794130451048 現在地"), completion: .value(completion),
        purpose: .value("")),
      agentProcess: agent)
  }
}
