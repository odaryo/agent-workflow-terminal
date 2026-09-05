import Foundation
import Testing

@testable import Adapters

@Suite("tmux 実行引数の組み立て")
struct TmuxRunnerTests {
  private let executableURL = URL(fileURLWithPath: "/test/bin/tmux")
  private let defaultTimeout = Duration.seconds(10)
  private let parentEnvironment = [
    "HOME": "/test/home",
    "PATH": "/test/bin:/usr/bin",
    "TMPDIR": "/must/not/inherit",
    "TMUX_TMPDIR": "/test/tmux",
    "LANG": "ja_JP.UTF-8",
    "SSH_AUTH_SOCK": "/must/not/inherit/agent.sock",
    "USER": "must-not-inherit",
  ]

  @Test("UTF-8 mode と専用 socket をサブコマンドより前へ置く")
  func buildsIsolatedUTF8Arguments() async throws {
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "ok\n", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    let result = try await runner.run(arguments: ["list-panes", "-a"])
    let invocation = try #require(await spy.invocations.first)

    #expect(invocation.executableURL == executableURL)
    #expect(invocation.arguments == ["-u", "-L", "awt-test", "list-panes", "-a"])
    #expect(result.stdout == "ok\n")
  }

  @Test("既定サーバでは -L を付けず、ユーザーが素の tmux で入れる名前空間を使う")
  func buildsUserDefaultServerArguments() async throws {
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let runner = try makeRunner(server: .userDefault, processRunner: spy)

    _ = try await runner.run(arguments: ["list-sessions", "-F", "#{session_name}"])

    #expect(
      await spy.invocations.first?.arguments == ["-u", "list-sessions", "-F", "#{session_name}"])
  }

  @Test("既定サーバでは socket 名の検証対象が無い")
  func skipsSocketNameValidationForUserDefaultServer() throws {
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))

    #expect(throws: Never.self) {
      try makeRunner(server: .userDefault, processRunner: spy)
    }
  }

  @Test("解析クライアントへ選択した環境変数だけを渡す")
  func selectsClientEnvironment() async throws {
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    _ = try await runner.run(arguments: ["display-message"])

    #expect(
      await spy.invocations.first?.environment
        == [
          "LC_ALL": "C",
          "HOME": "/test/home",
          "PATH": "/test/bin:/usr/bin",
          "TMUX_TMPDIR": "/test/tmux",
        ]
    )
  }

  @Test("既定タイムアウトを実行層へ渡す")
  func passesDefaultTimeout() async throws {
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    _ = try await runner.run(arguments: ["display-message"])

    #expect(await spy.invocations.first?.timeout == defaultTimeout)
  }

  @Test("明示したタイムアウトを実行層へ渡す")
  func passesExplicitTimeout() async throws {
    let timeout = Duration.milliseconds(250)
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    _ = try await runner.run(arguments: ["display-message"], timeout: timeout)

    #expect(await spy.invocations.first?.timeout == timeout)
  }

  @Test("既定と明示した出力上限を実行層へ渡す")
  func passesOutputLimit() async throws {
    let explicitLimit = 12_345
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    _ = try await runner.run(arguments: ["display-message"])
    _ = try await runner.run(arguments: ["list-panes"], outputLimit: explicitLimit)

    #expect(await spy.invocations.first?.outputLimit == TmuxRunner.defaultOutputLimit)
    #expect(await spy.invocations.last?.outputLimit == explicitLimit)
  }

  @Test("非ゼロ終了を終了コード・stdout・stderr を持つ tmux エラーにする")
  func convertsNonzeroExitToTmuxError() async throws {
    let spy = ProcessRunnerSpy(
      result: .success(.init(exitCode: 12, stdout: "partial", stderr: "bad command\n")))
    let runner = try makeRunner(processRunner: spy)

    do {
      _ = try await runner.run(arguments: ["not-a-command"])
      Issue.record("非ゼロ終了が成功として返された")
    } catch {
      #expect(
        error
          == .commandFailed(exitCode: 12, stdout: "partial", stderr: "bad command\n"))
    }
  }

  @Test("版数取得を専用 socket 経由で実行して警告を返す")
  func getsVersionWithWarnings() async throws {
    let spy = ProcessRunnerSpy(
      result: .success(.init(exitCode: 0, stdout: "tmux 3.4\n", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    let support = try await runner.version()

    #expect(await spy.invocations.first?.arguments == ["-u", "-L", "awt-test", "-V"])
    #expect(
      support
        == .supportedWithWarnings(
          .init(major: 3, minor: 4),
          Set([.zeroWidthJoinerGraphemeWidth])
        ))
  }

  @Test("解釈できない版数出力を unknown のまま返す")
  func getsUnknownVersion() async throws {
    let spy = ProcessRunnerSpy(
      result: .success(.init(exitCode: 0, stdout: "tmux master\n", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    let support = try await runner.version()

    #expect(support == .unknown(rawOutput: "tmux master\n"))
  }

  @Test("版数取得の非ゼロ終了を tmux エラーにする")
  func rejectsFailedVersionCommand() async throws {
    let spy = ProcessRunnerSpy(
      result: .success(.init(exitCode: 1, stdout: "partial", stderr: "failed\n")))
    let runner = try makeRunner(processRunner: spy)

    do {
      _ = try await runner.version()
      Issue.record("非ゼロ終了が成功として返された")
    } catch {
      #expect(error == .commandFailed(exitCode: 1, stdout: "partial", stderr: "failed\n"))
    }
  }

  @Test("候補順で最初の実行可能なバイナリを選ぶ")
  func resolvesFirstExecutableCandidateInOrder() async throws {
    let first = URL(fileURLWithPath: "/test/first/tmux")
    let second = URL(fileURLWithPath: "/test/second/tmux")
    let third = URL(fileURLWithPath: "/test/third/tmux")
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let runner = try makeRunner(
      processRunner: spy,
      executableCandidates: [first, second, third],
      isExecutableFile: { $0 != first }
    )

    _ = try await runner.run(arguments: ["display-message"])

    #expect(await spy.invocations.first?.executableURL == second)
  }

  @Test("実行可能な候補が無ければ候補を保持したエラーにする")
  func rejectsMissingBinary() {
    let candidates = [
      URL(fileURLWithPath: "/missing/first/tmux"),
      URL(fileURLWithPath: "/missing/second/tmux"),
    ]
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))

    #expect(throws: TmuxRunnerError.binaryNotFound(candidates: candidates)) {
      try makeRunner(
        processRunner: spy,
        executableCandidates: candidates,
        isExecutableFile: { _ in false }
      )
    }
  }

  @Test("path として解釈される slash 入り socket 名を拒否する")
  func rejectsPathLikeSocketName() {
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))

    #expect(throws: TmuxRunnerError.invalidSocketName("nested/socket")) {
      try makeRunner(server: .socketName("nested/socket"), processRunner: spy)
    }
  }

  private func makeRunner(
    server: TmuxServer = .socketName("awt-test"),
    processRunner: any ProcessRunning,
    executableCandidates: [URL]? = nil,
    isExecutableFile: @escaping @Sendable (URL) -> Bool = { _ in true }
  ) throws -> TmuxRunner {
    try TmuxRunner(
      server: server,
      processRunner: processRunner,
      executableCandidates: executableCandidates ?? [executableURL],
      parentEnvironment: parentEnvironment,
      isExecutableFile: isExecutableFile
    )
  }
}

private struct ProcessInvocation: Sendable, Equatable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]
  let timeout: Duration
  let outputLimit: Int
}

private actor ProcessRunnerSpy: ProcessRunning {
  private let result: Result<ProcessRunResult, ProcessRunnerError>
  private(set) var invocations: [ProcessInvocation] = []

  init(result: Result<ProcessRunResult, ProcessRunnerError>) {
    self.result = result
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(
      ProcessInvocation(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        timeout: timeout,
        outputLimit: outputLimit
      ))
    return try result.get()
  }
}
