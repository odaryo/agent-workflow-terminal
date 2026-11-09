import Testing

@testable import TerminalCore

@Suite("連携変数の形式違反の診断 (#673)")
struct PaneSummaryDiagnosticsTests {
  private static let malformedCompletions: [(String, PaneSummaryFormatViolation)] = [
    ("42 secret-token", .missingTurnStart),
    ("42 turn=invalid secret-token", .invalidTurnStart),
    ("42 turn=1794187512 secret-token", .turnStartOutOfRange),
    ("   ", .blank),
    ("secret-token", .missingAgentProcessID),
    ("42\tsecret-token", .missingSeparator),
    ("0 turn=1794187512000 secret-token", .agentProcessIDOutOfRange),
    ("42 turn=1794187512000 ", .emptyText),
    ("42 turn=1794187512000 secret-token\t", .containsLineBreakOrControlCharacter),
  ]

  @Test("完了の形式違反を pane と理由付きで1件返す", arguments: malformedCompletions)
  func completionDiagnostic(raw: String, violation: PaneSummaryFormatViolation) {
    var tracker = PaneSummaryDiagnosticTracker()
    let pane = summary(completion: .value(raw))
    #expect(
      tracker.newDiagnostics(for: [pane])
        == [diagnostic(option: .completion, violation: violation)])
  }

  @Test("同じ形式違反が続く間は最初の1回だけ返す")
  func repeatedViolationIsSuppressed() {
    var tracker = PaneSummaryDiagnosticTracker()
    let panes = [summary(completion: .value("42 secret-token"))]
    #expect(tracker.newDiagnostics(for: panes).count == 1)
    #expect(tracker.newDiagnostics(for: panes).isEmpty)
  }

  @Test("正常値への回復または pane 消失の後は同じ形式違反を再び返す", arguments: [false, true])
  func reportsAfterInterruption(paneDisappears: Bool) {
    var tracker = PaneSummaryDiagnosticTracker()
    let panes = [summary(completion: .value("42 secret-token"))]
    let expected = [diagnostic(option: .completion, violation: .missingTurnStart)]
    #expect(tracker.newDiagnostics(for: panes) == expected)
    let recovered = summary(completion: .value("42 turn=1794187512000 secret-token"))
    #expect(tracker.newDiagnostics(for: paneDisappears ? [] : [recovered]).isEmpty)
    #expect(tracker.newDiagnostics(for: panes) == expected)
  }

  @Test("違う形式違反に変わると1件返す")
  func reportsChangedViolation() {
    var tracker = PaneSummaryDiagnosticTracker()
    #expect(
      tracker.newDiagnostics(for: [summary(completion: .value("42 secret-token"))])
        == [diagnostic(option: .completion, violation: .missingTurnStart)])
    #expect(
      tracker.newDiagnostics(for: [summary(completion: .value("42 turn=invalid secret-token"))])
        == [diagnostic(option: .completion, violation: .invalidTurnStart)])
  }

  @Test("現在地の形式違反は status として返す")
  func statusDiagnostic() {
    var tracker = PaneSummaryDiagnosticTracker()
    #expect(
      tracker.newDiagnostics(for: [summary(status: .value("secret-status"))])
        == [diagnostic(option: .status, violation: .missingAgentProcessID)])
  }

  @Test(
    "プロセスの不一致・不在・曖昧・観測不能による読み捨ては診断しない",
    arguments: [
      PaneAgentProcess.identified(processID: 99), .notRunning,
      .ambiguous(processIDs: [42, 99]), .unobservable,
    ])
  func ignoresProcessDiscard(agent: PaneAgentProcess) {
    var tracker = PaneSummaryDiagnosticTracker()
    let pane = summary(
      status: .value("42 secret-status"),
      completion: .value("42 turn=1794187512000 secret-token"), agent: agent)
    #expect(tracker.newDiagnostics(for: [pane]).isEmpty)
  }

  @Test(
    "読み取り不能は診断しない",
    arguments: [
      PaneUserOptionUnreadableReason.tooLong, .containsLineBreakOrUnitSeparator,
      .invalidUTF8, .malformedOutput,
    ])
  func ignoresUnreadable(reason: PaneUserOptionUnreadableReason) {
    var tracker = PaneSummaryDiagnosticTracker()
    #expect(
      tracker.newDiagnostics(
        for: [summary(status: .unreadable(reason), completion: .unreadable(reason))]
      ).isEmpty)
  }

  @Test("未設定と目的の形式違反は診断しない", arguments: ["", "   ", "secret-purpose\t"])
  func ignoresUnsetAndPurpose(purpose: String) {
    var tracker = PaneSummaryDiagnosticTracker()
    #expect(tracker.newDiagnostics(for: [summary(purpose: .value(purpose))]).isEmpty)
  }

  @Test("複数 pane の診断は入力順で返す")
  func preservesPaneOrder() {
    var tracker = PaneSummaryDiagnosticTracker()
    let panes = [
      summary(paneID: "%9", completion: .value("42 secret-token")),
      summary(paneID: "%2", status: .value("secret-status")),
      summary(paneID: "%7", completion: .value("42 turn=invalid secret-token")),
    ]
    #expect(
      tracker.newDiagnostics(for: panes) == [
        diagnostic(paneID: "%9", option: .completion, violation: .missingTurnStart),
        diagnostic(paneID: "%2", option: .status, violation: .missingAgentProcessID),
        diagnostic(paneID: "%7", option: .completion, violation: .invalidTurnStart),
      ])
  }

  @Test("全形式違反のメッセージは空でなく、生値や token を含まない", arguments: malformedCompletions)
  func messagesExcludeRawValues(raw: String, violation: PaneSummaryFormatViolation) throws {
    var tracker = PaneSummaryDiagnosticTracker()
    let pane = summary(
      status: .value("42 secret-status"), completion: .value(raw), purpose: .value("secret-purpose")
    )
    let diagnostics = tracker.newDiagnostics(for: [pane])
    try #require(diagnostics.count == 1)
    let result = try #require(diagnostics.first)
    #expect(result.violation == violation)
    #expect(!result.message.isEmpty)
    for secret in [raw, "secret-token", "secret-status", "secret-purpose"] {
      #expect(!result.message.contains(secret))
    }
  }

  @Test("範囲外の診断は turn= とエポックミリ秒を案内する")
  func rangeMessageExplainsUnit() {
    let message = diagnostic(option: .completion, violation: .turnStartOutOfRange).message
    #expect(message.contains("turn="))
    #expect(message.contains("エポックミリ秒"))
  }

  @Test("旧形式の診断は新しい書式を案内する")
  func legacyMessageExplainsFormat() {
    let message = diagnostic(option: .completion, violation: .missingTurnStart).message
    #expect(message.contains("<agent-pid> turn=<エポックミリ秒> <token>"))
  }

  private func diagnostic(
    paneID: String = "%1", option: PaneSummaryDiagnostic.Option,
    violation: PaneSummaryFormatViolation
  ) -> PaneSummaryDiagnostic {
    PaneSummaryDiagnostic(paneID: PaneID(rawValue: paneID), option: option, violation: violation)
  }

  private func summary(
    paneID: String = "%1", status: PaneUserOptionReading = .value(""),
    completion: PaneUserOptionReading = .value(""), purpose: PaneUserOptionReading = .value(""),
    agent: PaneAgentProcess = .identified(processID: 42)
  ) -> PaneSummary {
    PaneSummary(
      paneID: PaneID(rawValue: paneID),
      readings: PaneSummaryReadings(status: status, completion: completion, purpose: purpose),
      agentProcess: agent)
  }
}
