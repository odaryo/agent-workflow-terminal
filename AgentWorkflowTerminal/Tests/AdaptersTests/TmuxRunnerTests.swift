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
      try makeRunner(processRunner: spy, socketName: "nested/socket")
    }
  }

  private func makeRunner(
    processRunner: any ProcessRunning,
    socketName: String = "awt-test",
    executableCandidates: [URL]? = nil,
    isExecutableFile: @escaping @Sendable (URL) -> Bool = { _ in true }
  ) throws -> TmuxRunner {
    try TmuxRunner(
      socketName: socketName,
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
