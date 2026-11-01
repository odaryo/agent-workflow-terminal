import Adapters
import Foundation
import Testing

@Suite("取り残された tmux server の lsof probe")
struct TmuxOrphanedServerProbeTests {
  @Test("既定の executable・argv・3秒の timeout で lsof を起動する")
  func usesDefaultInvocation() async {
    let runner = OrphanedServerRunnerStub(result: stubSuccess())
    _ = await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: measuredOrphanedSocketPath)

    #expect(await runner.environments.first?["LC_ALL"] == "C")
    #expect(
      await runner.invocations == [
        .init(
          executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
          arguments: ["-U", "-a", "-c", "tmux", "-F", "pn"], timeout: .seconds(3))
      ])
  }

  @Test("executable と timeout は注入できる")
  func usesInjectedConfiguration() async {
    let runner = OrphanedServerRunnerStub(result: stubSuccess())
    let executable = URL(fileURLWithPath: "/test/bin/lsof")
    _ = await TmuxOrphanedServerProbe(
      runner: runner, executable: executable, timeout: .milliseconds(250)
    ).probe(socketPath: measuredOrphanedSocketPath)

    #expect(await runner.invocations.first?.executableURL == executable)
    #expect(await runner.invocations.first?.timeout == .milliseconds(250))
  }

  @Test("exit 0 で socket の完全一致があれば orphaned")
  func findsOrphanedServer() async throws {
    let runner = OrphanedServerRunnerStub(result: stubSuccess(stdout: try measuredLsofOutput()))
    #expect(
      await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: measuredOrphanedSocketPath)
        == .orphaned(processIDs: [15199]))
  }

  @Test(
    "exit 0 の一致なしと exit 1 の空 stdout は absent",
    arguments: [
      ProcessRunResult(exitCode: 0, stdout: "", stderr: ""),
      ProcessRunResult(exitCode: 0, stdout: "p123\nn/another/socket\n", stderr: ""),
      ProcessRunResult(exitCode: 1, stdout: "", stderr: ""),
      ProcessRunResult(exitCode: 1, stdout: "", stderr: "diagnostic\n"),
    ])
  func reportsAbsence(output: ProcessRunResult) async {
    let runner = OrphanedServerRunnerStub(result: .success(output))
    #expect(
      await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: measuredOrphanedSocketPath)
        == .absent)
  }

  @Test(
    "exit 1 の非空 stdout とその他の終了コードは理由付きの undetermined",
    arguments: [
      ProcessRunResult(exitCode: 1, stdout: "p123\nn/socket\n", stderr: ""),
      ProcessRunResult(exitCode: 1, stdout: "\n", stderr: ""),
      ProcessRunResult(exitCode: 2, stdout: "", stderr: "lsof failed\n"),
      ProcessRunResult(exitCode: 2, stdout: "p123\nn/socket\n", stderr: "lsof failed\n"),
      ProcessRunResult(exitCode: 15, stdout: "", stderr: ""),
    ])
  func rejectsUncertainExit(output: ProcessRunResult) async {
    await expectUndetermined(.success(output))
  }

  @Test(
    "起動失敗・timeout などの実行エラーは理由付きの undetermined",
    arguments: [
      ProcessRunnerError.launchFailed(
        executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"), message: "not executable"),
      .timedOut(exitCode: nil, stdout: "", stderr: ""),
      .timedOut(exitCode: 0, stdout: "p123\nn/socket\n", stderr: ""),
      .cancelled,
      .outputLimitExceeded(limit: 10),
      .outputReadFailed(message: "read failed"),
      .invalidOutputLimit(-1),
    ])
  func rejectsRunnerFailure(error: ProcessRunnerError) async {
    await expectUndetermined(.failure(error))
  }

  private func expectUndetermined(_ result: TmuxSessionStubResult) async {
    let runner = OrphanedServerRunnerStub(result: result)
    let actual = await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: "/socket")
    guard case .undetermined(let reason) = actual else {
      Issue.record("理由付きの undetermined を期待したが、\(actual) が返った")
      return
    }
    #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

actor OrphanedServerRunnerStub: ProcessRunning {
  struct Invocation: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let timeout: Duration
  }

  private let result: TmuxSessionStubResult
  private(set) var invocations: [Invocation] = []
  private(set) var environments: [[String: String]] = []

  init(result: TmuxSessionStubResult) {
    self.result = result
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    environments.append(environment)
    invocations.append(
      .init(executableURL: executableURL, arguments: arguments, timeout: timeout))
    return try result.get()
  }
}
