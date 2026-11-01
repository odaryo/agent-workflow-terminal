import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("タブ単位の session 終了 (§3.1)")
struct TmuxSessionProvisionerTests {
  @Test("指定した番号の session を完全一致で確認する", arguments: [1, 3])
  func checksExactSession(index: Int) async throws {
    let key = try makeKey(index: index)
    let process = TerminationProcessRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
    let provisioner = try makeProvisioner(process)

    #expect(try await provisioner.exists(key))
    #expect(
      await process.calls == [
        ["-u", "has-session", "-t", "=\(TmuxSessionName(key: key).rawValue)"]
      ])
  }

  @Test("session または server が無ければ存在確認は false", arguments: [true, false])
  func absentSessionDoesNotExist(serverAbsent: Bool) async throws {
    let key = try makeKey(index: 2)
    let stderr =
      serverAbsent
      ? "no server running on /tmp/awt-test\n"
      : "can't find session: \(TmuxSessionName(key: key).rawValue)\n"
    let process = TerminationProcessRunner(result: .init(exitCode: 1, stdout: "", stderr: stderr))
    let provisioner = try makeProvisioner(process)

    #expect(try await !provisioner.exists(key))
  }

  @Test("分類できない存在確認の失敗を呼び出し側へ返す")
  func preservesExistenceFailure() async throws {
    let key = try makeKey(index: 2)
    let process = TerminationProcessRunner(
      result: .init(exitCode: 1, stdout: "", stderr: "permission denied\n"))
    let provisioner = try makeProvisioner(process)

    await #expect(throws: TmuxSessionOperationError.self) {
      try await provisioner.exists(key)
    }
  }

  @Test("指定した番号の session だけを完全一致で終了する", arguments: [1, 3])
  func terminatesExactSession(index: Int) async throws {
    let key = try makeKey(index: index)
    let process = TerminationProcessRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
    let provisioner = try makeProvisioner(process)

    try await provisioner.terminate(key)

    #expect(
      await process.calls == [
        ["-u", "kill-session", "-t", "=\(TmuxSessionName(key: key).rawValue)"]
      ])
  }

  @Test("session または server が既に無ければ成功する", arguments: [true, false])
  func absentSessionSucceeds(serverAbsent: Bool) async throws {
    let key = try makeKey(index: 2)
    let stderr =
      serverAbsent
      ? "no server running on /tmp/awt-test\n"
      : "can't find session: \(TmuxSessionName(key: key).rawValue)\n"
    let process = TerminationProcessRunner(result: .init(exitCode: 1, stdout: "", stderr: stderr))

    try await makeProvisioner(process).terminate(key)

    #expect(await process.calls.count == 1)
  }

  @Test("それ以外の失敗を呼び出し側へ返す")
  func preservesFailure() async throws {
    let key = try makeKey(index: 2)
    let process = TerminationProcessRunner(
      result: .init(exitCode: 1, stdout: "", stderr: "permission denied\n"))
    let provisioner = try makeProvisioner(process)

    await #expect(throws: TmuxSessionOperationError.self) {
      try await provisioner.terminate(key)
    }
  }

  private func makeKey(index: Int) throws -> TerminalSessionKey {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    return try #require(TerminalSessionKey(identity: identity, index: index))
  }

  private func makeProvisioner(_ process: TerminationProcessRunner) throws -> TmuxSessionProvisioner
  {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let runner = try TmuxRunner(
      server: .userDefault, processRunner: process, executableCandidates: [executable])
    return TmuxSessionProvisioner(runner: runner, tmuxExecutable: executable)
  }
}

private actor TerminationProcessRunner: ProcessRunning {
  let result: ProcessRunResult
  private(set) var calls: [[String]] = []

  init(result: ProcessRunResult) {
    self.result = result
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(arguments)
    return result
  }
}
