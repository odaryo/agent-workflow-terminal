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

  @Test("Resume では create が session の重複を返したあと detach-on-destroy と未設定の window-size を入れ直す")
  func resumeReappliesDetachOnDestroy() async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = TerminationProcessRunner(results: [
      .init(exitCode: 1, stdout: "", stderr: "can't find session: \(name)\n"),
      .init(exitCode: 1, stdout: "", stderr: "duplicate session: \(name)\n"),
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 0, stdout: "", stderr: ""),
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
        ["-u", "show-options", "-w", "-t", "=\(name):", "window-size"],
        ["-u", "set-option", "-w", "-t", "=\(name):", "window-size", "smallest"],
      ])
    #expect(
      result
        == .success(.init(command: ["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"])))
  }

  @Test("Resume で detach-on-destroy の設定に失敗しても attach の argv を返す")
  func resumeIgnoresDetachOnDestroyFailure() async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = TerminationProcessRunner(results: [
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 1, stdout: "", stderr: "no such session: =\(name):\n"),
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 0, stdout: "", stderr: ""),
    ])

    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")

    #expect(
      await process.calls == [
        ["-u", "has-session", "-t", "=\(name)"],
        ["-u", "set-option", "-t", "=\(name):", "detach-on-destroy", "on"],
        ["-u", "show-options", "-w", "-t", "=\(name):", "window-size"],
        ["-u", "set-option", "-w", "-t", "=\(name):", "window-size", "smallest"],
      ])
    #expect(
      result
        == .success(.init(command: ["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"])))
  }

  @Test("Resume では既存の window-size を保持する")
  func resumeKeepsExistingWindowSize() async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = TerminationProcessRunner(results: [
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 0, stdout: "window-size largest\n", stderr: ""),
    ])

    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")

    #expect(
      await process.calls == [
        ["-u", "has-session", "-t", "=\(name)"],
        ["-u", "set-option", "-t", "=\(name):", "detach-on-destroy", "on"],
        ["-u", "show-options", "-w", "-t", "=\(name):", "window-size"],
      ])
    #expect(
      result
        == .success(.init(command: ["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"])))
  }

  @Test(
    "Resume で window-size の確認や設定に失敗しても attach の argv を返す",
    arguments: [true, false])
  func resumeIgnoresWindowSizeFailure(showOptionsFails: Bool) async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let success = ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
    let failure = ProcessRunResult(exitCode: 1, stdout: "", stderr: "permission denied\n")
    let process = TerminationProcessRunner(
      results: [success, success] + (showOptionsFails ? [failure] : [success, failure]))

    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")

    var expectedCalls = [
      ["-u", "has-session", "-t", "=\(name)"],
      ["-u", "set-option", "-t", "=\(name):", "detach-on-destroy", "on"],
      ["-u", "show-options", "-w", "-t", "=\(name):", "window-size"],
    ]
    if !showOptionsFails {
      expectedCalls.append(
        ["-u", "set-option", "-w", "-t", "=\(name):", "window-size", "smallest"])
    }
    #expect(await process.calls == expectedCalls)
    #expect(
      result
        == .success(.init(command: ["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"])))
  }

  @Test(
    "bootstrap 後の Resume でも detach-on-destroy に続けて未設定の window-size を修復する",
    arguments: [true, false])
  func bootstrapResumeRepairsSession(detachOnDestroyFails: Bool) async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = TerminationProcessRunner(results: [
      .init(exitCode: 1, stdout: "", stderr: "no server running on /tmp/awt-test\n"),
      .init(exitCode: 1, stdout: "", stderr: "can't find session: \(name)\n"),
      .init(exitCode: 1, stdout: "", stderr: "duplicate session: \(name)\n"),
      .init(
        exitCode: detachOnDestroyFails ? 1 : 0, stdout: "",
        stderr: detachOnDestroyFails ? "permission denied\n" : ""),
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 0, stdout: "", stderr: ""),
      .init(exitCode: 0, stdout: "", stderr: ""),
    ])

    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")

    #expect(
      await process.calls == [
        ["-u", "has-session", "-t", "=\(name)"],
        ["-u", "has-session", "-t", "=\(name)"],
        ["-u", "new-session", "-d", "-s", name, "-c", "/", "-P", "-F", "#{session_id}"],
        ["-u", "set-option", "-t", "=\(name):", "detach-on-destroy", "on"],
        ["-u", "show-options", "-w", "-t", "=\(name):", "window-size"],
        ["-u", "set-option", "-w", "-t", "=\(name):", "window-size", "smallest"],
        ["-u", "kill-session", "-t", "=awt-bootstrap-server-do-not-use"],
      ])
    #expect(
      result
        == .success(.init(command: ["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"])))
  }

  @Test(
    "bootstrap の後始末の失敗は、create 成功なら注意、失敗なら元の原因とともに返す",
    arguments: [true, false],
    [
      Result<ProcessRunResult, ProcessRunnerError>.success(
        .init(exitCode: 1, stdout: "", stderr: "permission denied\n")),
      .success(
        .init(
          exitCode: 2, stdout: "", stderr: "can't find session: awt-bootstrap-server-do-not-use\n")),
      .success(.init(exitCode: 1, stdout: "", stderr: "can't find session: another-session\n")),
      .failure(.timedOut(exitCode: nil, stdout: "", stderr: "")),
      .failure(
        .launchFailed(executableURL: URL(fileURLWithPath: "/usr/bin/true"), message: "denied")),
    ])
  func reportsBootstrapCleanupFailure(
    createSucceeds: Bool, cleanup: Result<ProcessRunResult, ProcessRunnerError>
  ) async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = bootstrapProcess(name: name, createSucceeds: createSucceeds, cleanup: cleanup)
    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")
    let cleanupFailure: TmuxRunnerError =
      switch cleanup {
      case .success(let output):
        .commandFailed(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
      case .failure(let error): .process(error)
      }

    if createSucceeds {
      let attachment = try result.get()
      #expect(attachment.command == ["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"])
      let warning = try #require(attachment.warning)
      #expect(warning.contains(Self.cleanupInstruction))
      #expect(warning.contains("\(cleanupFailure)"))
    } else {
      let cause = TmuxSessionOperationError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: "create denied\n"))
      let error = TmuxSessionProvisionerError.leftoverBootstrapSession(
        cause: cause, cleanupFailure: cleanupFailure)
      #expect(result == .failure(error))
      #expect(error.terminalTabDescription.contains(cause.terminalTabDescription))
      #expect(error.terminalTabDescription.contains(Self.cleanupInstruction))
      #expect(error.terminalTabDescription.contains("\(cleanupFailure)"))
    }
    #expect(
      await process.calls.last == ["-u", "kill-session", "-t", "=awt-bootstrap-server-do-not-use"])
  }

  @Test(
    "bootstrap の後始末が成功または既に不在なら注意を返さず create の結果を保つ",
    arguments: [true, false],
    [
      ProcessRunResult(exitCode: 0, stdout: "", stderr: ""),
      .init(
        exitCode: 1, stdout: "", stderr: "can't find session: awt-bootstrap-server-do-not-use\n"),
      .init(exitCode: 1, stdout: "", stderr: "no such session: awt-bootstrap-server-do-not-use\n"),
      .init(exitCode: 1, stdout: "", stderr: "no such window: awt-bootstrap-server-do-not-use\n"),
      .init(exitCode: 1, stdout: "", stderr: "no server running on /tmp/awt-test\n"),
      Self.socketMissing,
    ])
  func absentBootstrapNeedsNoWarning(createSucceeds: Bool, cleanup: ProcessRunResult) async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = bootstrapProcess(
      name: name, createSucceeds: createSucceeds, cleanup: .success(cleanup))

    let result = try await makeProvisioner(process).attachCommand(for: key, workingDirectory: "/")

    if createSucceeds {
      #expect(
        result
          == .success(.init(command: ["/usr/bin/true", "-u", "attach-session", "-t", "=\(name)"])))
    } else {
      #expect(
        result
          == .failure(
            .operation(.tmux(.commandFailed(exitCode: 1, stdout: "", stderr: "create denied\n")))))
    }
  }

  private static let cleanupInstruction =
    "手で `tmux kill-session -t =awt-bootstrap-server-do-not-use` を実行してください"

  private func bootstrapProcess(
    name: String, createSucceeds: Bool, cleanup: Result<ProcessRunResult, ProcessRunnerError>
  ) -> TerminationProcessRunner {
    let success = ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
    let creation = ProcessRunResult(
      exitCode: createSucceeds ? 0 : 1, stdout: createSucceeds ? "$1\n" : "",
      stderr: createSucceeds ? "" : "create denied\n")
    let results: [ProcessRunResult] =
      [
        .init(exitCode: 1, stdout: "", stderr: "no server running on /tmp/awt-test\n"),
        .init(exitCode: 1, stdout: "", stderr: "can't find session: \(name)\n"),
        creation,
      ] + (createSucceeds ? [success] : [])
    return TerminationProcessRunner(outcomes: results.map { .success($0) } + [cleanup])
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
  let outcomes: [Result<ProcessRunResult, ProcessRunnerError>]
  private(set) var calls: [[String]] = []

  init(result: ProcessRunResult) {
    self.outcomes = [.success(result)]
  }

  init(results: [ProcessRunResult]) {
    self.outcomes = results.map { .success($0) }
  }

  init(outcomes: [Result<ProcessRunResult, ProcessRunnerError>]) {
    self.outcomes = outcomes
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(arguments)
    return try outcomes[min(calls.count - 1, outcomes.count - 1)].get()
  }
}
