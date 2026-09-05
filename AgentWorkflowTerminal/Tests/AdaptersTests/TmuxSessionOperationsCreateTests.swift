import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("設計書 §3.3 / §4.2 / §4.4 の session 作成が渡す引数と途中失敗")
struct TmuxSessionOperationsCreateTests: TmuxSessionOperationsTestSupport {

  // MARK: - 作成

  @Test("作成は server の存在を確かめてから、session ID を狙って設定する")
  func createsSessionWithProductDefaults() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(handler: createHandler(name: name))
    // 作業ディレクトリの検査は escape 前の値で行う。escape 後を渡していれば
    // `workingDirectoryUnusable` で止まる。
    let raw = workingDirectory
    let operations = try makeOperations(stub, canEnterDirectory: { $0 == raw })

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
    let stub = TmuxSessionRunnerStub(handler: createHandler(name: name))
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
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
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
    let stub = TmuxSessionRunnerStub { arguments in
      if arguments.contains("has-session") {
        return stubFailure(stderr: "can't find session: \(name.rawValue)\n")
      }
      return stubFailure(stderr: "duplicate session: \(name.rawValue)\n")
    }
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionAlreadyExists(name)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
  }

  @Test(
    "server が動いていなければ session を作らない",
    arguments: tmuxServerAbsentStderrs
  )
  func doesNotCreateSessionWithoutServer(stderr: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.serverNotRunning) {
      try await operations.create(
        session: try sessionName(), workingDirectory: workingDirectory)
    }
    // 存否確認だけで止まり、server を起動し得る new-session を撃たない。
    #expect(await stub.invocations.count == 1)
  }

  @Test(
    "tmux が受け付けない history-limit を tmux へ渡さない",
    arguments: [-1, -2_147_483_648, 2_147_483_648, 99_999_999_999]
  )
  func rejectsOutOfRangeHistoryLimit(historyLimit: Int) async throws {
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
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
    let stub = TmuxSessionRunnerStub(handler: createHandler(name: name))

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
    let stub = TmuxSessionRunnerStub(
      handler: createHandler(
        name: name,
        killSession: stubSuccess(),
        rest: stubFailure(stderr: tmuxConfigureFailureStderr)))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(tmuxConfigureFailureStderr)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
    #expect(
      await stub.invocations.last?.arguments == prefix + ["kill-session", "-t", sessionID])
  }

  /// 設定の連鎖は `$N` 宛に撃つので、tmux のメッセージにも `$N` が現れる。session 名で照合すると
  /// 一致せず、`create` が投げる型が `sessionNotFound` から一般の tmux エラーへ変わる。
  @Test("設定の途中で session が消えていたら、session ID 宛のメッセージも sessionNotFound へ写す")
  func mapsSessionIDAddressedFailureDuringConfiguration() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(
      handler: createHandler(
        name: name,
        killSession: stubSuccess(),
        rest: stubFailure(stderr: "can't find session: \(sessionID)\n")))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
  }

  @Test("後始末にも失敗したら、残った session と両方の原因を返す")
  func reportsLeftoverSessionWhenCleanupFails() async throws {
    let name = try sessionName()
    let cleanupStderr = "server exited unexpectedly\n"
    let stub = TmuxSessionRunnerStub(
      handler: createHandler(
        name: name,
        killSession: stubFailure(stderr: cleanupStderr),
        rest: stubFailure(stderr: tmuxConfigureFailureStderr)))

    await #expect(
      throws: TmuxSessionOperationError.leftoverSession(
        name,
        cause: tmuxFailure(tmuxConfigureFailureStderr),
        cleanupFailure: tmuxFailure(cleanupStderr))
    ) {
      try await makeOperations(stub).create(session: name, workingDirectory: workingDirectory)
    }
  }

  @Test("後始末の対象が既に無ければ、元の原因だけを投げる", arguments: tmuxCleanupTargetGoneStderrs)
  func reportsOriginalCauseWhenCleanupTargetIsGone(cleanupStderr: String) async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(
      handler: createHandler(
        name: name,
        killSession: stubFailure(stderr: cleanupStderr),
        rest: stubFailure(stderr: tmuxConfigureFailureStderr)))

    await #expect(throws: tmuxFailure(tmuxConfigureFailureStderr)) {
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
    let stub = TmuxSessionRunnerStub(
      handler: createHandler(
        name: name,
        newSessionStdout: stdout,
        killSession: stubFailure(stderr: "can't find session: \(name.rawValue)\n")))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.unexpectedSessionIDOutput(stdout)) {
      try await operations.create(session: name, workingDirectory: workingDirectory)
    }
    #expect(
      await stub.invocations.last?.arguments
        == prefix + ["kill-session", "-t", "=\(name.rawValue)"])
  }
}
