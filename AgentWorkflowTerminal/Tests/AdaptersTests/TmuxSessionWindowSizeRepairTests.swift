import Adapters
import Testing

@Suite("既存 session の window-size 修復 (設計書 §3.3 / §4.2)")
struct TmuxSessionWindowSizeRepairTests: TmuxSessionOperationsTestSupport {
  @Test("window 単位で未設定なら完全一致 target で問い合わせてから smallest を設定する")
  func appliesDefaultWhenUnset() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(result: stubSuccess())

    let result = try await makeOperations(stub).ensureWindowSizeIfUnset(session: name)

    #expect(result == .applied(.smallest))
    #expect(
      await stub.invocations.map(\.arguments)
        == [
          prefix + ["show-options", "-w", "-t", "=\(name.rawValue):", "window-size"],
          prefix + ["set-option", "-w", "-t", "=\(name.rawValue):", "window-size", "smallest"],
        ])
  }

  @Test("ユーザーの値も前回アプリが入れた値も上書きしない", arguments: ["largest", "smallest"])
  func keepsExistingWindowSize(value: String) async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(result: stubSuccess(stdout: "window-size \(value)\n"))

    let result = try await makeOperations(stub).ensureWindowSizeIfUnset(session: name)

    #expect(result == .keptExisting(value))
    #expect(
      await stub.invocations.map(\.arguments)
        == [prefix + ["show-options", "-w", "-t", "=\(name.rawValue):", "window-size"]])
  }

  @Test(
    "想定外の option 名や複数行は原文付きのエラーにして設定しない",
    arguments: ["window-sizz smallest\n", "window-size largest\nwindow-size smallest\n"]
  )
  func rejectsUnexpectedOutput(stdout: String) async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(result: stubSuccess(stdout: stdout))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.unexpectedShowOptionsOutput(stdout)) {
      try await operations.ensureWindowSizeIfUnset(session: name)
    }
    #expect(
      await stub.invocations.map(\.arguments)
        == [prefix + ["show-options", "-w", "-t", "=\(name.rawValue):", "window-size"]])
  }

  @Test("show-options が no such window を返す session は sessionNotFound に写す")
  func reportsMissingSession() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(
      result: stubFailure(stderr: "no such window: =\(name.rawValue):\n"))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.ensureWindowSizeIfUnset(session: name)
    }
    #expect(
      await stub.invocations.map(\.arguments)
        == [prefix + ["show-options", "-w", "-t", "=\(name.rawValue):", "window-size"]])
  }

  @Test("show-options 後に session が消えたら set-option の no such window を sessionNotFound に写す")
  func reportsSessionDisappearingBeforeSetOption() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(handler: { arguments in
      if arguments.contains("set-option") {
        return stubFailure(stderr: "no such window: =\(name.rawValue):\n")
      }
      return stubSuccess()
    })
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.ensureWindowSizeIfUnset(session: name)
    }
    #expect(
      await stub.invocations.map(\.arguments)
        == [
          prefix + ["show-options", "-w", "-t", "=\(name.rawValue):", "window-size"],
          prefix + ["set-option", "-w", "-t", "=\(name.rawValue):", "window-size", "smallest"],
        ])
  }

  @Test(
    "server の停止と socket の欠落を既存のエラー写像で区別する",
    arguments: [
      (tmuxServerNotRunningStderr, TmuxSessionOperationError.serverNotRunning),
      (
        tmuxServerSocketMissingStderr,
        TmuxSessionOperationError.serverSocketMissing(socketPath: "/private/tmp/tmux-501/default")
      ),
    ]
  )
  func reportsMissingServer(
    stderr: String,
    expectedError: TmuxSessionOperationError
  ) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: expectedError) {
      try await operations.ensureWindowSizeIfUnset(session: try sessionName())
    }
  }
}
