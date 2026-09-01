import Adapters
import Foundation
import Testing

@Suite("tmux 実行引数の組み立て")
struct TmuxRunnerTests {
  private let executableURL = URL(fileURLWithPath: "/test/bin/tmux")
  private let defaultTimeout = Duration.seconds(10)

  @Test("専用 socket とサブコマンドを argv で渡し LC_ALL を固定する")
  func buildsIsolatedArgumentsAndEnvironment() async throws {
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "ok\n", stderr: "")))
    let runner = try makeRunner(processRunner: spy)

    let result = try await runner.run(arguments: ["list-panes", "-a"])
    let invocation = try #require(await spy.invocations.first)

    #expect(invocation.executableURL == executableURL)
    #expect(invocation.arguments == ["-L", "awt-test", "list-panes", "-a"])
    #expect(invocation.environment["LC_ALL"] == "C")
    #expect(result.stdout == "ok\n")
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

  @Test("非ゼロ終了を終了コードと stderr を持つ tmux エラーにする")
  func convertsNonzeroExitToTmuxError() async throws {
    let spy = ProcessRunnerSpy(
      result: .success(.init(exitCode: 12, stdout: "partial", stderr: "bad command\n")))
    let runner = try makeRunner(processRunner: spy)

    do {
      _ = try await runner.run(arguments: ["not-a-command"])
      Issue.record("非ゼロ終了が成功として返された")
    } catch {
      #expect(error == .commandFailed(exitCode: 12, stderr: "bad command\n"))
    }
  }

  @Test("実行可能な候補が無ければ候補を保持したエラーにする")
  func rejectsMissingBinary() {
    let candidates = [
      URL(fileURLWithPath: "/missing/first/tmux"),
      URL(fileURLWithPath: "/missing/second/tmux"),
    ]
    let spy = ProcessRunnerSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))

    #expect(throws: TmuxRunnerError.binaryNotFound(candidates: candidates)) {
      try TmuxRunner(
        socketName: "awt-test",
        processRunner: spy,
        executableCandidates: candidates,
        isExecutableFile: { _ in false }
      )
    }
  }

  private func makeRunner(processRunner: any ProcessRunning) throws -> TmuxRunner {
    try TmuxRunner(
      socketName: "awt-test",
      processRunner: processRunner,
      executableCandidates: [executableURL],
      isExecutableFile: { _ in true }
    )
  }
}

private struct ProcessInvocation: Sendable, Equatable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]
  let timeout: Duration
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
    timeout: Duration
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(
      ProcessInvocation(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        timeout: timeout
      ))
    return try result.get()
  }
}
