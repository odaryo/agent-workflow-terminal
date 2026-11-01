import Adapters
import Testing

@Suite("既存 session の detach-on-destroy 設定")
struct TmuxSessionDetachOnDestroyTests: TmuxSessionOperationsTestSupport {
  @Test("detach-on-destroy は末尾コロン付きの完全一致 target に session 単位で設定する")
  func ensuresDetachOnDestroyWithExactSessionTarget() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(result: stubSuccess())

    try await makeOperations(stub).ensureDetachOnDestroy(session: name)

    #expect(
      await stub.invocations.map(\.arguments)
        == [prefix + ["set-option", "-t", "=\(name.rawValue):", "detach-on-destroy", "on"]])
  }

  @Test("設定対象の session が無ければ sessionNotFound を返す")
  func reportsMissingSession() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(
      result: stubFailure(stderr: "no such session: =\(name.rawValue):\n"))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.ensureDetachOnDestroy(session: name)
    }
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
      try await operations.ensureDetachOnDestroy(session: try sessionName())
    }
  }
}
