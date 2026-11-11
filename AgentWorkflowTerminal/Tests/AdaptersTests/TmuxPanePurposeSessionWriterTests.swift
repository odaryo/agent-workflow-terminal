import Adapters
import Foundation
import TerminalCore
import Testing

/// `hostctl worktree open --purpose` で受けた目的を、新しく作ったセッションへ書く (Issue #837)。
@Suite("目的の事前検査とセッション指定の書き込み (設計書 §12.7 / §21.4)")
struct TmuxPanePurposeSessionWriterTests {
  private static func makeSession() throws -> TmuxSessionName {
    TmuxSessionName(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/handoff-purpose")))
  }

  private func makeWriter() throws -> (TmuxPanePurposeWriter, ObservationProcessSpy) {
    let spy = ObservationProcessSpy()
    return (
      TmuxPanePurposeWriter(
        runner: try makeTmuxRunner(socketName: "purpose-session-test", processRunner: spy)), spy
    )
  }

  @Test(
    "書ける値と、見えない scalar だけの値 (削除になる) は検査を通す",
    arguments: [
      "Issue の概要", "-u", "a;b", "a; ", "設計；", "\u{6DD}", "\u{2800}", "", "   ", "\u{3000}",
      "\u{FEFF}", "\u{200B}", " \u{FEFF} ", "\n", "\u{85}", "\u{2028}", " \n ",
    ])
  func validateAccepts(text: String) throws {
    try TmuxPanePurposeWriter.validate(text)
  }

  @Test(
    "見える文字と改行・制御文字・行区切りの混在は拒否する",
    arguments: [
      "1行目\n2行目", "末尾改行\n", "a\tb", "a\u{1B}b", "a\u{85}b", "a\u{2028}b", "a\u{2029}b",
      "a\rb",
    ])
  func validateRejectsLineBreak(text: String) {
    #expect(throws: TmuxPanePurposeWriterError.containsLineBreakOrControlCharacter) {
      try TmuxPanePurposeWriter.validate(text)
    }
  }

  @Test(
    "UTF-8 の末尾のバイトが ; なら拒否する",
    arguments: ["foo;", #"a\;"#, "end;;", ";", "設計 ;", "a\u{600};", "\u{6DD};"])
  func validateRejectsTrailingSemicolon(text: String) {
    #expect(throws: TmuxPanePurposeWriterError.endsWithSemicolon) {
      try TmuxPanePurposeWriter.validate(text)
    }
  }

  @Test("; の後に空白があれば末尾の ; ではない")
  func validateAcceptsSemicolonFollowedBySpace() throws {
    try TmuxPanePurposeWriter.validate("a; ")
    try TmuxPanePurposeWriter.validate(";\u{3000}")
  }

  @Test("1024 バイトちょうどは通し、1025 バイトは拒否する")
  func validateByteLimit() throws {
    let atLimit = String(repeating: "a", count: 1024)
    try TmuxPanePurposeWriter.validate(atLimit)
    #expect(throws: TmuxPanePurposeWriterError.tooLong(byteCount: 1025, limit: 1024)) {
      try TmuxPanePurposeWriter.validate(atLimit + "a")
    }
  }

  @Test("マルチバイト文字が境界を跨ぐ値はバイト数で判定する")
  func validateByteLimitWithMultibyte() throws {
    // 3 バイト × 341 = 1023 バイト。1 バイト足すと 1024、3 バイト足すと 1026。
    let base = String(repeating: "あ", count: 341)
    try TmuxPanePurposeWriter.validate(base + "a")
    #expect(throws: TmuxPanePurposeWriterError.tooLong(byteCount: 1026, limit: 1024)) {
      try TmuxPanePurposeWriter.validate(base + "あ")
    }
  }

  @Test("検査の順は setPurpose(_:of:) と同じく改行、末尾の ;、長さ")
  func validateOrder() {
    #expect(throws: TmuxPanePurposeWriterError.containsLineBreakOrControlCharacter) {
      try TmuxPanePurposeWriter.validate("a\nb;")
    }
    #expect(throws: TmuxPanePurposeWriterError.containsLineBreakOrControlCharacter) {
      try TmuxPanePurposeWriter.validate(String(repeating: "a", count: 1100) + "\n")
    }
    #expect(throws: TmuxPanePurposeWriterError.endsWithSemicolon) {
      try TmuxPanePurposeWriter.validate(String(repeating: "a", count: 1100) + ";")
    }
  }

  @Test("セッションの active な pane を =<name>: で指定し、値の前に -- を置く")
  func setsPurposeOfActivePane() async throws {
    let session = try Self.makeSession()
    let (writer, spy) = try makeWriter()
    try await writer.setPurpose("-u Issue の概要", ofActivePaneIn: session)

    #expect(
      await spy.invocations == [
        [
          "-u", "-L", "purpose-session-test", "set-option", "-p", "-t",
          "=\(session.rawValue):", "--", "@awt_purpose", "-u Issue の概要",
        ]
      ])
  }

  @Test("見えない scalar だけなら -u で削除する", arguments: ["", "   ", "\u{FEFF}", "\u{3000}"])
  func clearsInvisibleOnlyPurposeOfActivePane(text: String) async throws {
    let session = try Self.makeSession()
    let (writer, spy) = try makeWriter()
    try await writer.setPurpose(text, ofActivePaneIn: session)

    #expect(
      await spy.invocations == [
        [
          "-u", "-L", "purpose-session-test", "set-option", "-p", "-u", "-t",
          "=\(session.rawValue):", "@awt_purpose",
        ]
      ])
  }

  @Test("検査で弾く値は tmux へ渡さない")
  func rejectsInvalidPurposeBeforeRunningTmux() async throws {
    let session = try Self.makeSession()
    let (writer, spy) = try makeWriter()
    await #expect(throws: TmuxPanePurposeWriterError.containsLineBreakOrControlCharacter) {
      try await writer.setPurpose("1行目\n2行目", ofActivePaneIn: session)
    }
    await #expect(throws: TmuxPanePurposeWriterError.endsWithSemicolon) {
      try await writer.setPurpose("foo;", ofActivePaneIn: session)
    }
    await #expect(throws: TmuxPanePurposeWriterError.tooLong(byteCount: 1025, limit: 1024)) {
      try await writer.setPurpose(
        String(repeating: "a", count: 1025), ofActivePaneIn: session)
    }
    #expect(await spy.invocations.isEmpty)
  }

  @Test("tmux の失敗は .tmux で返す")
  func reportsTmuxFailure() async throws {
    let session = try Self.makeSession()
    let writer = TmuxPanePurposeWriter(
      runner: try makeTmuxRunner(
        socketName: "purpose-session-test", processRunner: FailingTmuxProcessRunner()))
    do {
      try await writer.setPurpose("Issue の概要", ofActivePaneIn: session)
      Issue.record("tmux の失敗を返さなかった")
    } catch {
      guard case .tmux = error else {
        Issue.record("tmux の失敗が .tmux で返らなかった: \(error)")
        return
      }
    }
  }
}

private struct FailingTmuxProcessRunner: ProcessRunning {
  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    ProcessRunResult(exitCode: 1, stdout: "", stderr: "failed\n")
  }
}
