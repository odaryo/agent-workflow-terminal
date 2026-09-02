import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("設計書 §9.2 / §10 のテキスト注入が渡す引数")
struct TmuxTextInjectionTests {
  private let executableURL = URL(fileURLWithPath: "/test/bin/tmux")
  private let prefix = ["-u", "-L", "awt-test"]
  private let pane = PaneID(rawValue: "%3")

  @Test("注入は load-buffer と paste-buffer -p だけで組み立て、send-keys を使わない")
  func injectsThroughLoadBufferAndPasteBuffer() async throws {
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    try await injection.inject("hello\nworld\n", into: pane)

    let invocations = await spy.invocations
    #expect(invocations.count == 2)
    let load = try #require(invocations.first)
    let paste = try #require(invocations.last)
    let bufferName = try #require(load.arguments.dropFirst(5).first)
    let path = try #require(load.arguments.last)
    #expect(load.arguments == prefix + ["load-buffer", "-b", bufferName, path])
    #expect(
      paste.arguments == prefix + ["paste-buffer", "-p", "-d", "-b", bufferName, "-t", "%3"])
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
  func removesTemporaryFileOnEveryPath(_ pasteExitCode: Int32) async throws {
    let spy = ProcessRunnerSpy(
      results: ["paste-buffer": .init(exitCode: pasteExitCode, stdout: "", stderr: "boom\n")])
    let injection = try makeInjection(spy)

    _ = try? await injection.inject("text", into: pane)

    let path = try #require(await spy.invocations.first?.arguments.last)
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test("buffer 名は注入ごとに変え、ユーザーの同名 buffer を巻き込まない")
  func usesAFreshBufferNamePerInjection() async throws {
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)

    try await injection.inject("a", into: pane)
    try await injection.inject("b", into: pane)

    let names = await spy.invocations
      .filter { $0.arguments.contains("load-buffer") }
      .compactMap { $0.arguments.dropFirst(5).first }
    #expect(names.count == 2)
    #expect(names[0] != names[1])
  }

  @Test("paste が失敗したら、その buffer を消してからエラーを返す")
  func deletesTheBufferWhenPasteFails() async throws {
    let spy = ProcessRunnerSpy(
      results: [
        "paste-buffer": .init(exitCode: 1, stdout: "", stderr: "can't find pane: %3\n")
      ])
    let injection = try makeInjection(spy)

    await #expect(throws: TmuxTextInjectionError.paneNotFound(pane)) {
      try await injection.inject("text", into: pane)
    }

    let invocations = await spy.invocations
    let bufferName = try #require(invocations.first?.arguments.dropFirst(5).first)
    #expect(
      invocations.compactMap { $0.arguments.dropFirst(3).first }
        == ["load-buffer", "paste-buffer", "delete-buffer"])
    #expect(invocations.last?.arguments == prefix + ["delete-buffer", "-b", bufferName])
  }

  @Test("load-buffer が失敗したときは、作られていない buffer を消しにいかない")
  func skipsBufferDeletionWhenLoadFails() async throws {
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

    #expect(await spy.invocations.count == 1)
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
    "bracketed paste を抜け出せる制御文字を含むテキストを tmux へ渡す前に拒否する",
    arguments: ["\u{1b}[201~rm -rf /", "a\u{00}b", "a\u{07}b", "a\u{7f}b", "a\u{9b}201~b"]
  )
  func rejectsControlCharactersBeforeRunningTmux(_ text: String) async throws {
    let spy = ProcessRunnerSpy()
    let injection = try makeInjection(spy)
    let offending = try #require(
      text.unicodeScalars.first { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) })

    await #expect(throws: TmuxTextInjectionError.unsafeControlCharacter(offending)) {
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
      results: ["paste-buffer": .init(exitCode: 1, stdout: "", stderr: stderr)])
    let injection = try makeInjection(spy)

    await #expect(
      throws: TmuxTextInjectionError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: stderr))
    ) {
      try await injection.inject("text", into: pane)
    }
  }

  private func makeInjection(_ spy: ProcessRunnerSpy) throws -> TmuxTextInjection {
    TmuxTextInjection(
      runner: try TmuxRunner(
        socketName: "awt-test",
        processRunner: spy,
        executableCandidates: [executableURL],
        parentEnvironment: [:],
        isExecutableFile: { _ in true }
      ))
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
    if subcommand == "load-buffer", let path = arguments.last {
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
