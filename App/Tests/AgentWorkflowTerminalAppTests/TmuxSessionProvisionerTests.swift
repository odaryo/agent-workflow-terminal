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

    await #expect(throws: TmuxSessionProvisionerError.self) {
      try await provisioner.terminate(key)
    }
  }

  @Test("socket が消えて server が取り残されていれば、terminate は成功にしない")
  func terminateFailsForOrphanedServer() async throws {
    let key = try makeKey(index: 2)
    let process = TerminationProcessRunner(result: Self.socketMissing)
    let provisioner = try makeProvisioner(process, lsof: Self.lsofListening(on: Self.socketPath))

    await #expect(
      throws: TmuxSessionProvisionerError.orphanedServer(
        socketPath: Self.socketPath, .orphaned(processIDs: [4242]))
    ) {
      try await provisioner.terminate(key)
    }
  }

  @Test("取り残された server の有無を確かめられなければ、terminate は成功にしない")
  func terminateFailsWhenProbeIsUndetermined() async throws {
    let key = try makeKey(index: 2)
    let process = TerminationProcessRunner(result: Self.socketMissing)
    let provisioner = try makeProvisioner(
      process, lsof: .init(exitCode: 2, stdout: "", stderr: "lsof: error\n"))

    await #expect(throws: TmuxSessionProvisionerError.self) {
      try await provisioner.terminate(key)
    }
  }

  @Test("socket が消えていて server も居なければ、terminate は成功する")
  func terminateSucceedsWhenServerIsAbsent() async throws {
    let key = try makeKey(index: 2)
    let process = TerminationProcessRunner(result: Self.socketMissing)
    let provisioner = try makeProvisioner(
      process, lsof: .init(exitCode: 1, stdout: "", stderr: ""))

    try await provisioner.terminate(key)
  }

  @Test("socket が消えて server が取り残されていれば、session の一覧は空にせず投げる")
  func sessionNamesThrowsForOrphanedServer() async throws {
    let process = TerminationProcessRunner(result: Self.socketMissing)
    let provisioner = try makeProvisioner(process, lsof: Self.lsofListening(on: Self.socketPath))

    await #expect(
      throws: TmuxSessionProvisionerError.orphanedServer(
        socketPath: Self.socketPath, .orphaned(processIDs: [4242]))
    ) {
      try await provisioner.sessionNames()
    }
  }

  @Test("socket が消えていて server も居なければ、session の一覧は空")
  func sessionNamesIsEmptyWhenServerIsAbsent() async throws {
    let process = TerminationProcessRunner(result: Self.socketMissing)
    let provisioner = try makeProvisioner(
      process, lsof: .init(exitCode: 1, stdout: "", stderr: ""))

    #expect(try await provisioner.sessionNames().isEmpty)
  }

  @Test("socket が消えて server が取り残されていれば、新しい server を起こさず失敗を返す")
  func attachDoesNotBootstrapOverOrphanedServer() async throws {
    let key = try makeKey(index: 2)
    let process = TerminationProcessRunner(result: Self.socketMissing)
    let provisioner = try makeProvisioner(process, lsof: Self.lsofListening(on: Self.socketPath))

    let result = await provisioner.attachCommand(for: key, workingDirectory: "/")

    #expect(
      result
        == .failure(
          .orphanedServer(socketPath: Self.socketPath, .orphaned(processIDs: [4242]))))
    #expect(await process.calls.count == 1)
  }

  @Test("失敗の文言は pid と kill -USR1 の手順を示す")
  func orphanedExplanationNamesPidAndSignal() {
    let text = TmuxOrphanedServerProbeResult.orphaned(processIDs: [4242, 77])
      .orphanedServerExplanation(socketPath: Self.socketPath)

    #expect(text.contains(Self.socketPath))
    #expect(text.contains("4242, 77"))
    #expect(text.contains("kill -USR1 4242"))
    #expect(text.contains("kill -USR1 77"))
  }

  @Test("Resume では create が session の重複を返したあと detach-on-destroy を入れ直す")
  func resumeReappliesDetachOnDestroy() async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = TerminationProcessRunner(results: [
      .init(exitCode: 1, stdout: "", stderr: "can't find session: \(name)\n"),
      .init(exitCode: 1, stdout: "", stderr: "duplicate session: \(name)\n"),
      .init(exitCode: 0, stdout: "", stderr: ""),
    ])

    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")

    #expect(
      await process.calls == [
        ["-u", "has-session", "-t", "=\(name)"],
        [
          "-u", "new-session", "-d", "-s", name, "-c", "/", "-P", "-F", "#{session_id}",
        ],
        ["-u", "set-option", "-t", "=\(name):", "detach-on-destroy", "on"],
      ])
    #expect(result == .success(["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"]))
  }

  @Test("Resume で detach-on-destroy の設定に失敗しても attach の argv を返す")
  func resumeIgnoresDetachOnDestroyFailure() async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = TerminationProcessRunner(results: [
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 1, stdout: "", stderr: "no such session: =\(name):\n"),
    ])

    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")

    #expect(
      await process.calls == [
        ["-u", "has-session", "-t", "=\(name)"],
        ["-u", "set-option", "-t", "=\(name):", "detach-on-destroy", "on"],
      ])
    #expect(result == .success(["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"]))
  }

  private static let socketPath = "/tmp/awt-test/default"
  private static let socketMissing = ProcessRunResult(
    exitCode: 1, stdout: "",
    stderr: "error connecting to \(socketPath) (No such file or directory)\n")

  private static func lsofListening(on path: String) -> ProcessRunResult {
    .init(exitCode: 0, stdout: "p4242\nn\(path)\n", stderr: "")
  }

  private func makeKey(index: Int) throws -> TerminalSessionKey {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    return try #require(TerminalSessionKey(identity: identity, index: index))
  }

  private func makeProvisioner(
    _ process: TerminationProcessRunner,
    lsof: ProcessRunResult = .init(exitCode: 1, stdout: "", stderr: "")
  ) throws -> TmuxSessionProvisioner {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let runner = try TmuxRunner(
      server: .userDefault, processRunner: process, executableCandidates: [executable])
    return TmuxSessionProvisioner(
      runner: runner, tmuxExecutable: executable,
      orphanedServerProbe: TmuxOrphanedServerProbe(
        runner: TerminationProcessRunner(result: lsof)))
  }
}

private actor TerminationProcessRunner: ProcessRunning {
  /// 呼ばれた順に返す。尽きたら最後の結果を返し続ける。
  let results: [ProcessRunResult]
  private(set) var calls: [[String]] = []

  init(result: ProcessRunResult) {
    self.results = [result]
  }

  init(results: [ProcessRunResult]) {
    self.results = results
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(arguments)
    return results[min(calls.count - 1, results.count - 1)]
  }
}
