import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("設計書 §3.3 / §4.1 の tmux session 操作が渡す引数")
struct TmuxSessionOperationsTests {
  private let executableURL = URL(fileURLWithPath: "/test/bin/tmux")
  private let prefix = ["-u", "-L", "awt-test"]
  private let workingDirectory = "/repo/wt/feature-a"

  // MARK: - 存否確認

  @Test("存否確認は完全一致の target で問い合わせる")
  func checksExistenceWithExactTarget() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    #expect(try await operations.exists(session: name))
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["has-session", "-t", "=\(name.rawValue)"])
  }

  @Test("session が無いことを Bool の false で返す")
  func reportsMissingSessionAsFalse() async throws {
    let name = try sessionName()
    let stub = try stub(exitCode: 1, stderr: "can't find session: \(name.rawValue)\n")
    let operations = try makeOperations(stub)

    #expect(try await operations.exists(session: name) == false)
  }

  @Test("server が動いていないことも存否としては false へ畳む")
  func reportsMissingServerAsFalse() async throws {
    let stub = try stub(exitCode: 1, stderr: "no server running on /private/tmp/tmux-501/default\n")
    let operations = try makeOperations(stub)

    #expect(try await operations.exists(session: try sessionName()) == false)
  }

  @Test("分類できない失敗は存否へ畳まず tmux エラーのまま返す")
  func keepsUnclassifiedFailureOnExistenceCheck() async throws {
    let stub = try stub(exitCode: 1, stderr: "unknown command: has-session\n")
    let operations = try makeOperations(stub)

    await #expect(
      throws: TmuxSessionOperationError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: "unknown command: has-session\n"))
    ) {
      try await operations.exists(session: try sessionName())
    }
  }

  // MARK: - 作成

  @Test("作成は1回の実行で、最初の pane と残る window に設定が効く手順を送る")
  func createsSessionWithProductDefaults() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.create(session: name, workingDirectory: workingDirectory)

    #expect(await stub.invocations.count == 1)
    #expect(
      await stub.invocations.first?.arguments
        == prefix + [
          "new-session", "-d", "-s", name.rawValue, "-c", workingDirectory,
          ";", "set-option", "-t", name.rawValue, "history-limit", "10000",
          ";", "new-window", "-d", "-t", name.rawValue, "-c", workingDirectory,
          ";", "kill-window", "-t", "\(name.rawValue):^",
          ";", "set-option", "-w", "-t", "\(name.rawValue):", "window-size", "smallest",
        ])
  }

  @Test("履歴上限と window サイズは引数で上書きできる", arguments: TmuxWindowSize.allCases)
  func createsSessionWithOverriddenLimits(windowSize: TmuxWindowSize) async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.create(
      session: name,
      workingDirectory: workingDirectory,
      historyLimit: 500,
      windowSize: windowSize
    )

    #expect(
      await stub.invocations.first?.arguments
        == prefix + [
          "new-session", "-d", "-s", name.rawValue, "-c", workingDirectory,
          ";", "set-option", "-t", name.rawValue, "history-limit", "500",
          ";", "new-window", "-d", "-t", name.rawValue, "-c", workingDirectory,
          ";", "kill-window", "-t", "\(name.rawValue):^",
          ";", "set-option", "-w", "-t", "\(name.rawValue):", "window-size", windowSize.rawValue,
        ])
  }

  @Test("同名 session の存在を成功にも一般エラーにも丸めない")
  func reportsDuplicateSession() async throws {
    let name = try sessionName()
    let stub = try stub(exitCode: 1, stderr: "duplicate session: \(name.rawValue)\n")
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionAlreadyExists(name)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
  }

  @Test("作業ディレクトリが無ければ tmux を起動する前に失敗する")
  func rejectsMissingWorkingDirectory() async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub, directoryExists: { _ in false })

    await #expect(throws: TmuxSessionOperationError.workingDirectoryNotFound(workingDirectory)) {
      try await operations.create(session: try sessionName(), workingDirectory: workingDirectory)
    }
    #expect(await stub.invocations.isEmpty)
  }

  // MARK: - 終了

  @Test("終了も完全一致の target で行う")
  func killsSessionWithExactTarget() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.kill(session: name)

    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["kill-session", "-t", "=\(name.rawValue)"])
  }

  @Test("既に無い session の終了を成功へ丸めない")
  func reportsMissingSessionOnKill() async throws {
    let name = try sessionName()
    let stub = try stub(exitCode: 1, stderr: "can't find session: \(name.rawValue)\n")
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.kill(session: name)
    }
  }

  @Test("server ごと落ちている場合も終了は成功にしない")
  func reportsMissingServerOnKill() async throws {
    let stub = try stub(exitCode: 1, stderr: "no server running on /private/tmp/tmux-501/default\n")
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.serverNotRunning) {
      try await operations.kill(session: try sessionName())
    }
  }

  // MARK: - 一覧

  @Test("一覧は server にある session 名を prefix で絞らずに返す")
  func listsEverySessionName() async throws {
    let stub = ProcessRunnerStub(
      result: .success(
        .init(exitCode: 0, stdout: "awt-feature-a-0badcafe\nuser-plain\n0\n", stderr: "")))
    let operations = try makeOperations(stub)

    #expect(try await operations.list() == ["awt-feature-a-0badcafe", "user-plain", "0"])
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["list-sessions", "-F", "#{session_name}"])
  }

  @Test("server が動いていなければ一覧は空になる")
  func listsNothingWithoutServer() async throws {
    let stub = try stub(exitCode: 1, stderr: "no server running on /private/tmp/tmux-501/default\n")
    let operations = try makeOperations(stub)

    #expect(try await operations.list().isEmpty)
  }

  // MARK: - Helpers

  private func sessionName(
    _ identityPath: String = "/repo/.git/worktrees/feature-a"
  ) throws -> TmuxSessionName {
    TmuxSessionName(identity: try #require(WorktreeIdentity(rawValue: identityPath)))
  }

  private func stub(exitCode: Int32, stderr: String) throws -> ProcessRunnerStub {
    ProcessRunnerStub(result: .success(.init(exitCode: exitCode, stdout: "", stderr: stderr)))
  }

  private func makeOperations(
    _ stub: ProcessRunnerStub,
    directoryExists: @escaping @Sendable (String) -> Bool = { _ in true }
  ) throws -> TmuxSessionOperations {
    TmuxSessionOperations(
      runner: try TmuxRunner(
        socketName: "awt-test",
        processRunner: stub,
        executableCandidates: [executableURL],
        parentEnvironment: [:],
        isExecutableFile: { _ in true }
      ),
      directoryExists: directoryExists
    )
  }
}

private struct StubInvocation: Sendable, Equatable {
  let arguments: [String]
}

private actor ProcessRunnerStub: ProcessRunning {
  private let result: Result<ProcessRunResult, ProcessRunnerError>
  private(set) var invocations: [StubInvocation] = []

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
    invocations.append(StubInvocation(arguments: arguments))
    return try result.get()
  }
}
