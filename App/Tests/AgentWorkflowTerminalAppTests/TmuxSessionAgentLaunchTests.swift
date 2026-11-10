import Adapters
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

extension TmuxSessionProvisionerTests {
  @Test("新しく作れた session にだけ attach 前に1回コマンドを送る", arguments: [true, false])
  func typesAgentCommandAfterCreation(bootstrap: Bool) async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let success = ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
    let absent = ProcessRunResult(
      exitCode: 1, stdout: "", stderr: "can't find session: \(name)\n")
    let prefix: [ProcessRunResult] =
      bootstrap
      ? [.init(exitCode: 1, stdout: "", stderr: "no server running on /tmp/awt-test\n")]
      : []
    let process = TerminationProcessRunner(
      results: prefix + [
        absent, .init(exitCode: 0, stdout: "$1\n", stderr: ""), success, success, success,
      ])

    let result = try await makeProvisioner(process).attachCommand(
      for: key, workingDirectory: "/", agentCommand: "agent")
    let attachment = try result.get()
    let calls = await process.calls
    #expect(
      calls.filter { $0.contains("send-keys") } == [
        ["-u", "send-keys", "-t", "=\(name):", "-H", "61", "67", "65", "6e", "74", "0d"]
      ])
    #expect(attachment.warning == nil)
    #expect(attachment.command.last == "=\(name)")
    if bootstrap {
      #expect(calls.last == ["-u", "kill-session", "-t", "=awt-bootstrap-server-do-not-use"])
    } else {
      #expect(calls.last?.contains("send-keys") == true)
    }
  }

  @Test("session の作成に失敗したら Agent コマンドを送らない")
  func creationFailureDoesNotTypeAgentCommand() async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let process = TerminationProcessRunner(results: [
      .init(exitCode: 1, stdout: "", stderr: "can't find session: \(name)\n"),
      .init(exitCode: 1, stdout: "", stderr: "create denied\n"),
    ])

    let result = try await makeProvisioner(process).attachCommand(
      for: key, workingDirectory: "/", agentCommand: "agent")

    #expect(
      result
        == .failure(
          .operation(.tmux(.commandFailed(exitCode: 1, stdout: "", stderr: "create denied\n")))))
    #expect(await process.calls.count == 2)
  }

  @Test("Agent コマンドの送信失敗は attach を止めず警告にする", arguments: [true, false])
  func agentCommandFailureWarns(bootstrap: Bool) async throws {
    let key = try makeKey(index: 2)
    let name = TmuxSessionName(key: key).rawValue
    let success = ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
    let prefix: [ProcessRunResult] =
      bootstrap
      ? [.init(exitCode: 1, stdout: "", stderr: "no server running on /tmp/awt-test\n")]
      : []
    let process = TerminationProcessRunner(
      results: prefix + [
        .init(exitCode: 1, stdout: "", stderr: "can't find session: \(name)\n"),
        .init(exitCode: 0, stdout: "$1\n", stderr: ""), success,
        .init(exitCode: 1, stdout: "", stderr: "send denied\n"),
        .init(exitCode: 1, stdout: "", stderr: "cleanup denied\n"),
      ])

    let attachment = try await makeProvisioner(process).attachCommand(
      for: key, workingDirectory: "/", agentCommand: "agent"
    ).get()
    let warning = try #require(attachment.warning)
    #expect(warning.contains("Agent の起動コマンドを送れませんでした"))
    #expect(!warning.contains("session を用意できません"))
    #expect(warning.contains("send denied"))
    #expect(await process.calls.filter { $0.contains("send-keys") }.count == 1)
    if bootstrap { #expect(warning.contains(Self.cleanupInstruction)) }
  }

}
