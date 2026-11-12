import Adapters
import Foundation
import Testing

@Suite("§7.2 打ち切り実行の既定実装と git 境界")
struct ProcessRunOutputTests {
  @Test("§7.2 既定実装は部分出力の無い上限エラーをそのまま投げる")
  func defaultImplementationPreservesLimitError() async {
    let spy = RunOnlySpy(result: .failure(.outputLimitExceeded(limit: 17)))
    await #expect(throws: ProcessRunnerError.outputLimitExceeded(limit: 17)) {
      try await spy.runTruncatingAtOutputLimit(
        executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"],
        environment: ["LC_ALL": "C"], timeout: .seconds(2), outputLimit: 17)
    }
  }

  @Test("§7.2 既定実装は通常の結果を completed で返して引数を保つ")
  func defaultImplementationWrapsCompletedResult() async throws {
    let expected = ProcessRunResult(exitCode: 3, stdout: "out", stderr: "err")
    let spy = RunOnlySpy(result: .success(expected))
    let output = try await spy.runTruncatingAtOutputLimit(
      executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"],
      environment: ["LC_ALL": "C"], timeout: .seconds(2), outputLimit: 17)
    #expect(output == .completed(expected))
    let expectedCall = RunOutputCall(
      executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"],
      environment: ["LC_ALL": "C"], timeout: .seconds(2), outputLimit: 17)
    #expect(await spy.call == expectedCall)
  }

  @Test("§7.2 GitRunner は打ち切りを失敗に変えず実行条件を run と共有する")
  func gitPreservesTruncatedOutputAndInvocation() async throws {
    let expected = ProcessRunOutput.truncated(stdout: "prefix", stderr: "warning", limit: 17)
    let spy = TruncatingGitSpy(output: expected)
    let runner = try gitRunner(spy)
    let command = GitReadCommand.diffPatch(.unstaged)
    _ = try await runner.run(command, outputLimit: 17)
    let output = try await runner.runTruncatingAtOutputLimit(command, outputLimit: 17)
    #expect(output == expected)
    let regularCall = await spy.regularCall
    let truncatingCall = await spy.truncatingCall
    #expect(regularCall == truncatingCall)
    let call = try #require(await spy.truncatingCall)
    #expect(call.timeout == GitRunner.defaultTimeout)
    #expect(call.outputLimit == 17)
    #expect(call.environment["LC_ALL"] == "C")
  }

  @Test("§7.2 GitRunner は completed の非ゼロ終了を commandFailed にする")
  func gitRejectsNonzeroCompletedOutput() async throws {
    let spy = TruncatingGitSpy(
      output: .completed(ProcessRunResult(exitCode: 7, stdout: "out", stderr: "err")))
    let runner = try gitRunner(spy)
    await #expect(throws: GitRunnerError.commandFailed(exitCode: 7, stdout: "out", stderr: "err")) {
      try await runner.runTruncatingAtOutputLimit(.diffPatch(.unstaged), outputLimit: 17)
    }
  }

  private func gitRunner(_ spy: some ProcessRunning) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")])
  }
}

private struct RunOutputCall: Sendable, Equatable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]
  let timeout: Duration
  let outputLimit: Int
}

private actor RunOnlySpy: ProcessRunning {
  let result: Result<ProcessRunResult, ProcessRunnerError>
  private(set) var call: RunOutputCall?

  init(result: Result<ProcessRunResult, ProcessRunnerError>) {
    self.result = result
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    call = RunOutputCall(
      executableURL: executableURL, arguments: arguments, environment: environment,
      timeout: timeout, outputLimit: outputLimit)
    return try result.get()
  }
}

private actor TruncatingGitSpy: ProcessRunning {
  let output: ProcessRunOutput
  private(set) var regularCall: RunOutputCall?
  private(set) var truncatingCall: RunOutputCall?

  init(output: ProcessRunOutput) {
    self.output = output
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    regularCall = RunOutputCall(
      executableURL: executableURL, arguments: arguments, environment: environment,
      timeout: timeout, outputLimit: outputLimit)
    return ProcessRunResult(exitCode: 0, stdout: "ordinary", stderr: "")
  }

  func runTruncatingAtOutputLimit(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunOutput {
    truncatingCall = RunOutputCall(
      executableURL: executableURL, arguments: arguments, environment: environment,
      timeout: timeout, outputLimit: outputLimit)
    return output
  }
}
