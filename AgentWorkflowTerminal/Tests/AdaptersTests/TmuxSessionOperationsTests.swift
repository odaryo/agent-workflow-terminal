import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("設計書 §3.3 / §4.1 の session 存否確認・終了・一覧が渡す引数")
struct TmuxSessionOperationsTests: TmuxSessionOperationsTestSupport {

  // MARK: - 存否確認

  @Test("存否確認は完全一致の target で問い合わせる")
  func checksExistenceWithExactTarget() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
    let operations = try makeOperations(stub)

    #expect(try await operations.exists(session: name))
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["has-session", "-t", "=\(name.rawValue)"])
  }

  @Test("session が無いことを Bool の false で返す")
  func reportsMissingSessionAsFalse() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(
      result: stubFailure(stderr: "can't find session: \(name.rawValue)\n"))

    #expect(try await makeOperations(stub).exists(session: name) == false)
  }

  @Test(
    "server が動いていないことも存否としては false へ畳む",
    arguments: tmuxServerAbsentStderrs
  )
  func reportsMissingServerAsFalse(stderr: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))

    #expect(try await makeOperations(stub).exists(session: try sessionName()) == false)
  }

  @Test(
    "server 不在ではない接続失敗を存否へ畳まない",
    arguments: tmuxNotServerAbsentStderrs
  )
  func keepsNonAbsenceConnectionFailures(stderr: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(stderr)) {
      try await operations.exists(session: try sessionName())
    }
  }

  @Test("分類できない失敗は存否へ畳まず tmux エラーのまま返す")
  func keepsUnclassifiedFailureOnExistenceCheck() async throws {
    let stderr = "unknown command: has-session\n"
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(stderr)) {
      try await operations.exists(session: try sessionName())
    }
  }

  // MARK: - 終了

  @Test("終了も完全一致の target で行う")
  func killsSessionWithExactTarget() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(result: stubSuccess())

    try await makeOperations(stub).kill(session: name)

    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["kill-session", "-t", "=\(name.rawValue)"])
  }

  @Test("既に無い session の終了を成功へ丸めない")
  func reportsMissingSessionOnKill() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(
      result: stubFailure(stderr: "can't find session: \(name.rawValue)\n"))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.kill(session: name)
    }
  }

  @Test("server ごと落ちている場合も終了は成功にしない", arguments: tmuxServerAbsentStderrs)
  func reportsMissingServerOnKill(stderr: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.serverNotRunning) {
      try await operations.kill(session: try sessionName())
    }
  }

  // MARK: - 一覧

  @Test("一覧は server にある session 名を prefix で絞らずに返す")
  func listsEverySessionName() async throws {
    let stub = TmuxSessionRunnerStub(
      result: stubSuccess(stdout: "awt-feature-a-0badcafe\nuser-plain\n0\n"))
    let operations = try makeOperations(stub)

    #expect(try await operations.list() == ["awt-feature-a-0badcafe", "user-plain", "0"])
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["list-sessions", "-F", "#{session_name}"])
  }

  @Test("server が動いていなければ一覧は空になる", arguments: tmuxServerAbsentStderrs)
  func listsNothingWithoutServer(stderr: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))

    #expect(try await makeOperations(stub).list().isEmpty)
  }

  @Test("server 不在ではない接続失敗で一覧を空へ畳まない", arguments: tmuxNotServerAbsentStderrs)
  func keepsNonAbsenceConnectionFailuresOnList(stderr: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(stderr)) {
      try await operations.list()
    }
  }
}
