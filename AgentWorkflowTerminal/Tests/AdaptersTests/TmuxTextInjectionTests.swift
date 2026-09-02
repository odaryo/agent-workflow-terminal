import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("設計書 §9.2 / §10 のテキスト注入が渡す引数")
struct TmuxTextInjectionTests {
  private let executableURL = URL(fileURLWithPath: "/test/bin/tmux")
  private let prefix = ["-u", "-L", "awt-test"]
  private let pane = PaneID(rawValue: "%3")

  @Test("注入は load-buffer / 状態判定つき paste / buffer 削除の3コマンドで、send-keys を使わない")
  func injectsThroughLoadBufferAndGatedPasteBuffer() async throws {
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    try await injection.inject("hello\nworld\n", into: pane)

    let invocations = await spy.invocations
    #expect(invocations.count == 3)
    let load = try #require(invocations.first)
    let buffer = try #require(load.arguments.dropFirst(5).first)
    let token = String(buffer.dropFirst("awt-inject-".count))
    let path = try #require(load.arguments.last)
    #expect(load.arguments == prefix + ["load-buffer", "-b", buffer, path])
    #expect(
      invocations[1].arguments == prefix + [
        "if-shell", "-F", "-t", "%3", "#{pane_in_mode}",
        "delete-buffer -b awt-refused-copy-mode-\(token)",
        "if-shell -F -t %3 '#{pane_input_off}' "
          + "'delete-buffer -b awt-refused-input-off-\(token)' "
          + "'paste-buffer -p -d -b \(buffer) -t %3'",
      ])
    #expect(invocations[2].arguments == prefix + ["delete-buffer", "-b", buffer])
    #expect(invocations.allSatisfy { !$0.arguments.contains("send-keys") })
  }

  @Test("tmux が読む時点の一時ファイルは所有者だけが読め、注入テキストそのものが入っている")
  func writesTemporaryFileReadableOnlyByOwner() async throws {
    let text = "レビューコメント $PATH `id` \"q\" '\\' \t🙂\n"
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    try await injection.inject(text, into: pane)

    let load = try #require(await spy.invocations.first)
    #expect(load.fileContents == Data(text.utf8))
    #expect(load.filePermissions == 0o600)
  }

  @Test("成功しても失敗しても一時ファイルを残さない", arguments: [0, 1] as [Int32])
  func removesTemporaryFileOnEveryPath(_ gateExitCode: Int32) async throws {
    let spy = ProcessRunnerSpy(
      results: ["if-shell": .init(exitCode: gateExitCode, stdout: "", stderr: "boom\n")])
    let injection = try makeInjection(spy)

    _ = try? await injection.inject("text", into: pane)

    let path = try #require(await spy.invocations.first?.arguments.last)
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test("buffer 名と分岐用の sentinel は注入ごとに変え、ユーザーの同名 buffer を巻き込まない")
  func usesFreshNamesPerInjection() async throws {
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    try await injection.inject("a", into: pane)
    try await injection.inject("b", into: pane)

    let names = await spy.invocations
      .filter { $0.arguments.dropFirst(3).first == "load-buffer" }
      .compactMap { $0.arguments.dropFirst(5).first }
    #expect(names.count == 2)
    #expect(names[0] != names[1])
    let gates = await spy.invocations.filter { $0.arguments.dropFirst(3).first == "if-shell" }
    #expect(gates.count == 2)
    #expect(gates[0].arguments != gates[1].arguments)
  }

  @Test("load-buffer が失敗しても buffer を消しにいく (タイムアウト後に残り得るため)")
  func deletesTheBufferEvenWhenLoadFails() async throws {
    let stderr = "/nope: No such file or directory\n"
    let spy = ProcessRunnerSpy(
      results: ["load-buffer": .init(exitCode: 1, stdout: "", stderr: stderr)])
    let injection = try makeInjection(spy)

    await #expect(
      throws: TmuxTextInjectionError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: stderr))
    ) {
      try await injection.inject("text", into: pane)
    }

    let invocations = await spy.invocations
    #expect(
      invocations.compactMap { $0.arguments.dropFirst(3).first } == [
        "load-buffer", "delete-buffer",
      ])
    let buffer = try #require(invocations.first?.arguments.dropFirst(5).first)
    #expect(invocations.last?.arguments == prefix + ["delete-buffer", "-b", buffer])
  }

  @Test(
    "mode で送らなかった分岐は、その mode 名を載せて返す",
    arguments: ["copy-mode", "clock-mode", "tree-mode", ""]
  )
  func reportsPaneModeRefusalWithTheModeName(_ mode: String) async throws {
    let spy = SentinelFailingSpy(sentinelPrefix: "awt-refused-copy-mode-", paneMode: mode)
    let injection = try makeInjection(spy)

    await #expect(throws: TmuxTextInjectionError.paneInMode(pane, mode: mode)) {
      try await injection.inject("text", into: pane)
    }
    #expect(
      await spy.lastModeQuery == [
        "-u", "-L", "awt-test", "display-message", "-p", "-t", "%3",
        "#{pane_mode}",
      ])
  }

  @Test("入力を受け付けない pane で送らなかった分岐を、copy-mode とは別のエラーで返す")
  func reportsInputDisabledRefusal() async throws {
    let spy = SentinelFailingSpy(sentinelPrefix: "awt-refused-input-off-", paneMode: "")
    let injection = try makeInjection(spy)

    await #expect(throws: TmuxTextInjectionError.paneInputDisabled(pane)) {
      try await injection.inject("text", into: pane)
    }
  }

  @Test("この注入の sentinel でない unknown buffer は、送らなかった判定に丸めない")
  func keepsForeignUnknownBufferAsRawFailure() async throws {
    let stderr = "unknown buffer: awt-refused-copy-mode-somebody-else\n"
    let spy = ProcessRunnerSpy(
      results: ["if-shell": .init(exitCode: 1, stdout: "", stderr: stderr)])
    let injection = try makeInjection(spy)

    await #expect(
      throws: TmuxTextInjectionError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: stderr))
    ) {
      try await injection.inject("text", into: pane)
    }
  }

  @Test("空文字列の注入では tmux を一度も起動しない")
  func doesNotRunTmuxForEmptyText() async throws {
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    try await injection.inject("", into: pane)

    #expect(await spy.invocations.isEmpty)
  }

  @Test(
    "`%N` 以外の pane ID を tmux へ渡す前に拒否する",
    arguments: ["", "%", "3", "%x", "%-1", "% 1", "%0 ; kill-server", "@0", "-t"]
  )
  func rejectsMalformedPaneIDBeforeRunningTmux(_ rawValue: String) async throws {
    let malformed = PaneID(rawValue: rawValue)
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    await #expect(throws: TmuxTextInjectionError.invalidPaneID(malformed)) {
      try await injection.inject("text", into: malformed)
    }
    #expect(await spy.invocations.isEmpty)
  }

  @Test(
    "bracketed paste を抜け出せる制御文字は、位置つきで tmux へ渡す前に拒否する",
    arguments: [
      ("\u{1b}[201~rm -rf /", "\u{1b}" as Unicode.Scalar, 0),
      ("あ\u{00}b", "\u{00}" as Unicode.Scalar, 1),
      ("ab\u{07}", "\u{07}" as Unicode.Scalar, 2),
      ("a\tb\n\u{7f}", "\u{7f}" as Unicode.Scalar, 4),
      ("🙂\u{9b}201~", "\u{9b}" as Unicode.Scalar, 1),
    ]
  )
  func rejectsControlCharactersWithTheirPosition(
    _ text: String,
    _ scalar: Unicode.Scalar,
    _ offset: Int
  ) async throws {
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    await #expect(
      throws: TmuxTextInjectionError.unsafeControlCharacter(
        scalar: scalar, unicodeScalarOffset: offset)
    ) {
      try await injection.inject(text, into: pane)
    }
    #expect(await spy.invocations.isEmpty)
  }

  @Test("タブ・改行・復帰は本文の一部として通す")
  func allowsTabAndNewlineAndCarriageReturn() async throws {
    let text = "1行目\t列\r\n2行目\n"
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    try await injection.inject(text, into: pane)

    #expect(await spy.invocations.first?.fileContents == Data(text.utf8))
  }

  @Test("別 pane を指す can't find pane は対象 pane の不在に丸めない")
  func keepsMismatchedMissingPaneAsRawFailure() async throws {
    let stderr = "can't find pane: %9\n"
    let spy = ProcessRunnerSpy(
      results: ["if-shell": .init(exitCode: 1, stdout: "", stderr: stderr)])
    let injection = try makeInjection(spy)

    await #expect(
      throws: TmuxTextInjectionError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: stderr))
    ) {
      try await injection.inject("text", into: pane)
    }
  }

  @Test(
    "load-buffer へ渡す path の `#` を literal 化する (tmux が format 展開するため)",
    arguments: [
      ("/tmp/plain/awt-inject-1", "/tmp/plain/awt-inject-1"),
      ("/tmp/tst-#S.txt", "/tmp/tst-##S.txt"),
      ("/tmp/a#{session_name}b", "/tmp/a##{session_name}b"),
      ("/tmp/##", "/tmp/####"),
    ]
  )
  func escapesFormatExpansionInThePath(_ path: String, _ expected: String) {
    #expect(TmuxTextInjection.escapingFormats(path) == expected)
  }

  @Test("`#` を含む一時ディレクトリでも、tmux は本来の一時ファイルを読む")
  func escapesTheRealTemporaryFilePath() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "awt-fmt-#S-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy, temporaryDirectory: directory)

    try await injection.inject("body\n", into: pane)

    let load = try #require(await spy.invocations.first)
    let path = try #require(load.arguments.last)
    #expect(path.hasPrefix(TmuxTextInjection.escapingFormats(directory.path)))
    #expect(path.contains("awt-fmt-##S-"))
    #expect(load.fileContents == Data("body\n".utf8))
  }

  @Test("キャンセルで load-buffer が中断されても buffer を消しにいく")
  func deletesTheBufferWhenLoadIsCancelled() async throws {
    let spy = CancellingLoadSpy()
    let injection = try makeInjection(spy)

    await #expect(throws: TmuxTextInjectionError.tmux(.process(.cancelled))) {
      try await injection.inject("text", into: pane)
    }

    let invocations = await spy.invocations
    #expect(invocations.compactMap { $0.dropFirst(3).first } == ["load-buffer", "delete-buffer"])
    let buffer = try #require(invocations.first?.dropFirst(5).first)
    #expect(invocations.last == prefix + ["delete-buffer", "-b", buffer])
  }

  private func makeInjection(
    _ spy: some ProcessRunning,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws -> TmuxTextInjection {
    TmuxTextInjection(
      runner: try TmuxRunner(
        socketName: "awt-test",
        processRunner: spy,
        executableCandidates: [executableURL],
        parentEnvironment: [:],
        isExecutableFile: { _ in true }
      ),
      temporaryDirectory: temporaryDirectory)
  }
}

private struct SpyInvocation: Sendable, Equatable {
  let arguments: [String]
  /// `load-buffer` に渡された一時ファイルを tmux 起動時点で読んだもの。注入後に消えるため、
  /// この瞬間にしか観測できない。
  let fileContents: Data?
  let filePermissions: Int?
}

private actor ProcessRunnerSpy: ProcessRunning {
  /// tmux のサブコマンド名 → その実行が返す結果。未指定のサブコマンドは exit 0 になる。
  private let results: [String: ProcessRunResult]
  private(set) var invocations: [SpyInvocation] = []

  init(results: [String: ProcessRunResult] = [:]) {
    self.results = results
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    // `TmuxRunner` が前置する `-u -L <socket>` の次がサブコマンド名。
    let subcommand = arguments.dropFirst(3).first ?? ""
    var fileContents: Data?
    var filePermissions: Int?
    if subcommand == "load-buffer", let argument = arguments.last {
      // tmux 3.4 は path 引数を format 展開するので、`##` を `#` に戻してから読む (実測)。
      let path = argument.replacingOccurrences(of: "##", with: "#")
      fileContents = FileManager.default.contents(atPath: path)
      filePermissions =
        (try? FileManager.default.attributesOfItem(atPath: path))
        .flatMap { $0[.posixPermissions] as? NSNumber }?
        .intValue
    }
    invocations.append(
      SpyInvocation(
        arguments: arguments,
        fileContents: fileContents,
        filePermissions: filePermissions
      ))
    return results[subcommand] ?? ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
  }
}

/// 実 tmux が「送らなかった」分岐で返す形 (`delete-buffer -b <sentinel>` の失敗) を、
/// 引数に現れた sentinel 名から組み立てて返す。名前は注入ごとに変わるのでテストから固定できない。
private actor SentinelFailingSpy: ProcessRunning {
  private let sentinelPrefix: String
  private let paneMode: String
  private(set) var lastModeQuery: [String]?

  init(sentinelPrefix: String, paneMode: String) {
    self.sentinelPrefix = sentinelPrefix
    self.paneMode = paneMode
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    if arguments.dropFirst(3).first == "display-message" {
      lastModeQuery = arguments
      // 実 tmux の `display-message -p` は末尾に改行を付ける (実測)。
      return ProcessRunResult(exitCode: 0, stdout: paneMode + "\n", stderr: "")
    }
    guard arguments.dropFirst(3).first == "if-shell",
      let sentinel =
        arguments
        .flatMap({ $0.split(separator: " ").map { $0.trimmingCharacters(in: ["'"]) } })
        .first(where: { $0.hasPrefix(sentinelPrefix) })
    else {
      return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
    }
    return ProcessRunResult(
      exitCode: 1, stdout: "", stderr: "unknown buffer: \(sentinel)\n")
  }
}

/// `load-buffer` の途中で呼び出し元 Task がキャンセルされたときに `ProcessRunning` が返す形を
/// そのまま再現する。M1 の実トリガーはタイムアウトとキャンセルであり、単なる非ゼロ終了ではない。
private actor CancellingLoadSpy: ProcessRunning {
  private(set) var invocations: [[String]] = []

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    guard arguments.dropFirst(3).first == "load-buffer" else {
      return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
    }
    throw .cancelled
  }
}
