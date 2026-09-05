import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// tmux 3.4 が実際に返す server 不在のメッセージ。socket ファイルの状態で書き分けられる。
/// 実測: `-L <既に落ちた server の socket>` と `-L <一度も使っていない名前>` を撃って採取。
private let serverAbsentStderrs = [
  "no server running on /private/tmp/tmux-501/default\n",
  "error connecting to /private/tmp/tmux-501/default (No such file or directory)\n",
]

private let stubSessionID = "$3"

/// 後始末の `kill-session` が「対象はもう無い」と言う2通り (実測)。指定した session ID が
/// 消えている場合と、server ごと落ちて session も道連れになった場合。
private let cleanupTargetGoneStderrs =
  ["can't find session: \(stubSessionID)\n"] + serverAbsentStderrs

/// 同じ `error connecting to ` の前置きを持つが、server 不在ではない失敗 (実測)。
/// socket 名を300文字にしたときと、socket の位置に通常ファイルを置いたときに採取。
private let notServerAbsentStderrs = [
  "error connecting to /private/tmp/tmux-501/aaaa (File name too long)\n",
  "error connecting to /private/tmp/tmux-501/regular (Socket operation on non-socket)\n",
]

@Suite("設計書 §3.3 / §4.1 の tmux session 操作が渡す引数")
struct TmuxSessionOperationsTests {
  private let executableURL = URL(fileURLWithPath: "/test/bin/tmux")
  private let prefix = ["-u", "-L", "awt-test"]
  /// `#` を含むのは、`-c` の値の format 展開への対処を全 argv の検証と同じ場所で押さえるため。
  private let workingDirectory = "/repo/wt/#feature-a"
  private let escapedWorkingDirectory = "/repo/wt/##feature-a"
  private let sessionID = stubSessionID
  /// tmux 3.4 が `history-limit -1` に返す stderr。設定の途中失敗を代表させる。
  private static let configureStderr = "value is too small: -1\n"

  // MARK: - 存否確認

  @Test("存否確認は完全一致の target で問い合わせる")
  func checksExistenceWithExactTarget() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(result: success())
    let operations = try makeOperations(stub)

    #expect(try await operations.exists(session: name))
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["has-session", "-t", "=\(name.rawValue)"])
  }

  @Test("session が無いことを Bool の false で返す")
  func reportsMissingSessionAsFalse() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(
      result: failure(stderr: "can't find session: \(name.rawValue)\n"))

    #expect(try await makeOperations(stub).exists(session: name) == false)
  }

  @Test(
    "server が動いていないことも存否としては false へ畳む",
    arguments: serverAbsentStderrs
  )
  func reportsMissingServerAsFalse(stderr: String) async throws {
    let stub = ProcessRunnerStub(result: failure(stderr: stderr))

    #expect(try await makeOperations(stub).exists(session: try sessionName()) == false)
  }

  @Test(
    "server 不在ではない接続失敗を存否へ畳まない",
    arguments: notServerAbsentStderrs
  )
  func keepsNonAbsenceConnectionFailures(stderr: String) async throws {
    let stub = ProcessRunnerStub(result: failure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(stderr)) {
      try await operations.exists(session: try sessionName())
    }
  }

  @Test("分類できない失敗は存否へ畳まず tmux エラーのまま返す")
  func keepsUnclassifiedFailureOnExistenceCheck() async throws {
    let stderr = "unknown command: has-session\n"
    let stub = ProcessRunnerStub(result: failure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(stderr)) {
      try await operations.exists(session: try sessionName())
    }
  }

  // MARK: - 作成

  @Test("作成は server の存在を確かめてから、session ID を狙って設定する")
  func createsSessionWithProductDefaults() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(handler: createHandler(name: name))
    // 実在確認は escape 前の値で行う。escape 後を渡していれば `workingDirectoryNotFound` で止まる。
    let raw = workingDirectory
    let operations = try makeOperations(stub, directoryExists: { $0 == raw })

    try await operations.create(session: name, workingDirectory: workingDirectory)

    let invocations = await stub.invocations.map(\.arguments)
    #expect(invocations.count == 3)
    #expect(invocations[0] == prefix + ["has-session", "-t", "=\(name.rawValue)"])
    #expect(
      invocations[1]
        == prefix + [
          "new-session", "-d", "-s", name.rawValue, "-c", escapedWorkingDirectory,
          "-P", "-F", "#{session_id}",
        ])
    #expect(
      invocations[2]
        == prefix + [
          "set-option", "-t", sessionID, "history-limit", "10000",
          ";", "new-window", "-d", "-t", sessionID, "-c", escapedWorkingDirectory,
          ";", "kill-window", "-t", "\(sessionID):^",
          ";", "set-option", "-w", "-t", "\(sessionID):", "window-size", "smallest",
        ])
  }

  @Test("履歴上限と window サイズは引数で上書きできる", arguments: TmuxWindowSize.allCases)
  func createsSessionWithOverriddenLimits(windowSize: TmuxWindowSize) async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(handler: createHandler(name: name))
    let operations = try makeOperations(stub)

    try await operations.create(
      session: name,
      workingDirectory: workingDirectory,
      historyLimit: 500,
      windowSize: windowSize
    )

    #expect(
      await stub.invocations.last?.arguments
        == prefix + [
          "set-option", "-t", sessionID, "history-limit", "500",
          ";", "new-window", "-d", "-t", sessionID, "-c", escapedWorkingDirectory,
          ";", "kill-window", "-t", "\(sessionID):^",
          ";", "set-option", "-w", "-t", "\(sessionID):", "window-size", windowSize.rawValue,
        ])
  }

  @Test("同名 session の存在を成功にも一般エラーにも丸めない")
  func reportsDuplicateSessionFoundByProbe() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(result: success())
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionAlreadyExists(name)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
    // 存否確認で分かった時点で new-session を撃たない。
    #expect(await stub.invocations.count == 1)
  }

  @Test("探索の後に他クライアントが作った同名 session も専用のエラーにする")
  func reportsDuplicateSessionFoundByNewSession() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub { arguments in
      if arguments.contains("has-session") {
        return failure(stderr: "can't find session: \(name.rawValue)\n")
      }
      return failure(stderr: "duplicate session: \(name.rawValue)\n")
    }
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionAlreadyExists(name)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
  }

  @Test(
    "server が動いていなければ session を作らない",
    arguments: serverAbsentStderrs
  )
  func doesNotCreateSessionWithoutServer(stderr: String) async throws {
    let stub = ProcessRunnerStub(result: failure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.serverNotRunning) {
      try await operations.create(
        session: try sessionName(), workingDirectory: workingDirectory)
    }
    // 存否確認だけで止まり、server を起動し得る new-session を撃たない。
    #expect(await stub.invocations.count == 1)
  }

  @Test("作業ディレクトリが無ければ tmux を起動する前に失敗する")
  func rejectsMissingWorkingDirectory() async throws {
    let stub = ProcessRunnerStub(result: success())
    let operations = try makeOperations(stub, directoryExists: { _ in false })

    await #expect(throws: TmuxSessionOperationError.workingDirectoryNotFound(workingDirectory)) {
      try await operations.create(session: try sessionName(), workingDirectory: workingDirectory)
    }
    #expect(await stub.invocations.isEmpty)
  }

  @Test(
    "pane が渡した値を得られない作業ディレクトリを tmux へ渡さない",
    arguments: ["/repo/wt;", "", "/repo/wt/#[fg=red]", "/repo/#[", "/repo/wt/a##[b"]
  )
  func rejectsWorkingDirectoryAlteredByTmux(path: String) async throws {
    let stub = ProcessRunnerStub(result: success())
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.invalidWorkingDirectory(path)) {
      try await operations.create(session: try sessionName(), workingDirectory: path)
    }
    #expect(await stub.invocations.isEmpty)
  }

  @Test(
    "pane がそのまま受け取れる作業ディレクトリは弾かない",
    arguments: ["/repo/mid;dir", "/repo/wt\\", "/repo/wt/a\\b", "/repo/wt/#", "/repo/wt/#123"]
  )
  func allowsWorkingDirectoryPreservedByTmux(path: String) async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(handler: createHandler(name: name))

    try await makeOperations(stub).create(session: name, workingDirectory: path)

    #expect(await stub.invocations.count == 3)
  }

  @Test(
    "tmux が受け付けない history-limit を tmux へ渡さない",
    arguments: [-1, -2_147_483_648, 2_147_483_648, 99_999_999_999]
  )
  func rejectsOutOfRangeHistoryLimit(historyLimit: Int) async throws {
    let stub = ProcessRunnerStub(result: success())
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.invalidHistoryLimit(historyLimit)) {
      try await operations.create(
        session: try sessionName(),
        workingDirectory: workingDirectory,
        historyLimit: historyLimit
      )
    }
    #expect(await stub.invocations.isEmpty)
  }

  @Test("tmux が受け付ける範囲の端は通す", arguments: [0, 2_147_483_647])
  func acceptsHistoryLimitBounds(historyLimit: Int) async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(handler: createHandler(name: name))

    try await makeOperations(stub).create(
      session: name,
      workingDirectory: workingDirectory,
      historyLimit: historyLimit
    )

    #expect(await stub.invocations.count == 3)
  }

  // MARK: - 作成の途中失敗

  @Test("設定に失敗したら、作った session を session ID 指定で消してから原因を投げる")
  func cleansUpAfterConfigurationFailure() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(
      handler: createHandler(
        name: name, killSession: success(), rest: failure(stderr: Self.configureStderr)))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(Self.configureStderr)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
    #expect(
      await stub.invocations.last?.arguments == prefix + ["kill-session", "-t", sessionID])
  }

  @Test("後始末にも失敗したら、残った session と両方の原因を返す")
  func reportsLeftoverSessionWhenCleanupFails() async throws {
    let name = try sessionName()
    let cleanupStderr = "server exited unexpectedly\n"
    let stub = ProcessRunnerStub(
      handler: createHandler(
        name: name,
        killSession: failure(stderr: cleanupStderr),
        rest: failure(stderr: Self.configureStderr)))

    await #expect(
      throws: TmuxSessionOperationError.leftoverSession(
        name,
        cause: tmuxFailure(Self.configureStderr),
        cleanupFailure: tmuxFailure(cleanupStderr))
    ) {
      try await makeOperations(stub).create(session: name, workingDirectory: workingDirectory)
    }
  }

  @Test("後始末の対象が既に無ければ、元の原因だけを投げる", arguments: cleanupTargetGoneStderrs)
  func reportsOriginalCauseWhenCleanupTargetIsGone(cleanupStderr: String) async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(
      handler: createHandler(
        name: name,
        killSession: failure(stderr: cleanupStderr),
        rest: failure(stderr: Self.configureStderr)))

    await #expect(throws: tmuxFailure(Self.configureStderr)) {
      try await makeOperations(stub).create(session: name, workingDirectory: workingDirectory)
    }
  }

  @Test(
    "session ID として読めない出力でも session は残るので後始末する",
    arguments: ["", "\n", "3\n", "$\n", "%1\n"]
  )
  func cleansUpWhenSessionIDIsUnreadable(stdout: String) async throws {
    let name = try sessionName()
    // 後始末を「対象はもう無い」で終わらせる。tmux は `-t "=<name>"` の `=` を落とした名前で
    // 返すので (実測)、こちらが `=` 付きのまま照合していると `leftoverSession` になる。
    let stub = ProcessRunnerStub(
      handler: createHandler(
        name: name,
        newSessionStdout: stdout,
        killSession: failure(stderr: "can't find session: \(name.rawValue)\n")))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.unexpectedSessionIDOutput(stdout)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
    #expect(
      await stub.invocations.last?.arguments
        == prefix + ["kill-session", "-t", "=\(name.rawValue)"])
  }

  // MARK: - 終了

  @Test("終了も完全一致の target で行う")
  func killsSessionWithExactTarget() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(result: success())

    try await makeOperations(stub).kill(session: name)

    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["kill-session", "-t", "=\(name.rawValue)"])
  }

  @Test("既に無い session の終了を成功へ丸めない")
  func reportsMissingSessionOnKill() async throws {
    let name = try sessionName()
    let stub = ProcessRunnerStub(
      result: failure(stderr: "can't find session: \(name.rawValue)\n"))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.kill(session: name)
    }
  }

  @Test("server ごと落ちている場合も終了は成功にしない", arguments: serverAbsentStderrs)
  func reportsMissingServerOnKill(stderr: String) async throws {
    let stub = ProcessRunnerStub(result: failure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.serverNotRunning) {
      try await operations.kill(session: try sessionName())
    }
  }

  // MARK: - 一覧

  @Test("一覧は server にある session 名を prefix で絞らずに返す")
  func listsEverySessionName() async throws {
    let stub = ProcessRunnerStub(
      result: success(stdout: "awt-feature-a-0badcafe\nuser-plain\n0\n"))
    let operations = try makeOperations(stub)

    #expect(try await operations.list() == ["awt-feature-a-0badcafe", "user-plain", "0"])
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["list-sessions", "-F", "#{session_name}"])
  }

  @Test("server が動いていなければ一覧は空になる", arguments: serverAbsentStderrs)
  func listsNothingWithoutServer(stderr: String) async throws {
    let stub = ProcessRunnerStub(result: failure(stderr: stderr))

    #expect(try await makeOperations(stub).list().isEmpty)
  }

  @Test("server 不在ではない接続失敗で一覧を空へ畳まない", arguments: notServerAbsentStderrs)
  func keepsNonAbsenceConnectionFailuresOnList(stderr: String) async throws {
    let stub = ProcessRunnerStub(result: failure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(stderr)) {
      try await operations.list()
    }
  }

  // MARK: - Helpers

  private func sessionName(
    _ identityPath: String = "/repo/.git/worktrees/feature-a"
  ) throws -> TmuxSessionName {
    TmuxSessionName(identity: try #require(WorktreeIdentity(rawValue: identityPath)))
  }

  /// 存否確認は不在、`new-session` は `newSessionStdout`、`kill-session` は `killSession`
  /// (省略時は `rest`)、残りは `rest` を返す。
  private func createHandler(
    name: TmuxSessionName,
    newSessionStdout: String? = nil,
    killSession: StubResult? = nil,
    rest: StubResult = success()
  ) -> StubHandler {
    let stdout = newSessionStdout ?? "\(sessionID)\n"
    return { arguments in
      if arguments.contains("has-session") {
        return failure(stderr: "can't find session: \(name.rawValue)\n")
      }
      if arguments.contains("new-session") { return success(stdout: stdout) }
      if let killSession, arguments.contains("kill-session") { return killSession }
      return rest
    }
  }

  private func tmuxFailure(_ stderr: String) -> TmuxSessionOperationError {
    .tmux(.commandFailed(exitCode: 1, stdout: "", stderr: stderr))
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

// MARK: - テストダブル

private typealias StubResult = Result<ProcessRunResult, ProcessRunnerError>
private typealias StubHandler = @Sendable ([String]) -> StubResult

private func success(stdout: String = "") -> StubResult {
  .success(.init(exitCode: 0, stdout: stdout, stderr: ""))
}

private func failure(exitCode: Int32 = 1, stderr: String) -> StubResult {
  .success(.init(exitCode: exitCode, stdout: "", stderr: stderr))
}

private struct StubInvocation: Sendable, Equatable {
  let arguments: [String]
}

private actor ProcessRunnerStub: ProcessRunning {
  private let handler: StubHandler
  private(set) var invocations: [StubInvocation] = []

  init(result: StubResult) {
    self.handler = { _ in result }
  }

  init(handler: @escaping StubHandler) {
    self.handler = handler
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(StubInvocation(arguments: arguments))
    return try handler(arguments).get()
  }
}
