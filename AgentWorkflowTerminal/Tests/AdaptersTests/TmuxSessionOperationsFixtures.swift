import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// tmux 3.4 が実際に返す server 不在のメッセージ。socket ファイルの状態で書き分けられる。
/// 実測: `-L <既に落ちた server の socket>` と `-L <一度も使っていない名前>` を撃って採取。
let tmuxServerAbsentStderrs = [
  "no server running on /private/tmp/tmux-501/default\n",
  "error connecting to /private/tmp/tmux-501/default (No such file or directory)\n",
]

/// 同じ `error connecting to ` の前置きを持つが、server 不在ではない失敗 (実測)。
/// socket 名を300文字にしたときと、socket の位置に通常ファイルを置いたときに採取。
let tmuxNotServerAbsentStderrs = [
  "error connecting to /private/tmp/tmux-501/aaaa (File name too long)\n",
  "error connecting to /private/tmp/tmux-501/regular (Socket operation on non-socket)\n",
]

let tmuxStubSessionID = "$3"

/// 後始末の `kill-session` が「対象はもう無い」と言う2通り (実測)。指定した session ID が
/// 消えている場合と、server ごと落ちて session も道連れになった場合。
let tmuxCleanupTargetGoneStderrs =
  ["can't find session: \(tmuxStubSessionID)\n"] + tmuxServerAbsentStderrs

/// tmux 3.4 が `history-limit -1` に返す stderr。設定の途中失敗を代表させる。
let tmuxConfigureFailureStderr = "value is too small: -1\n"

typealias TmuxSessionStubResult = Result<ProcessRunResult, ProcessRunnerError>
typealias TmuxSessionStubHandler = @Sendable ([String]) -> TmuxSessionStubResult

func stubSuccess(stdout: String = "") -> TmuxSessionStubResult {
  .success(.init(exitCode: 0, stdout: stdout, stderr: ""))
}

func stubFailure(exitCode: Int32 = 1, stderr: String) -> TmuxSessionStubResult {
  .success(.init(exitCode: exitCode, stdout: "", stderr: stderr))
}

/// `TmuxSessionOperations` の単体テストが共有する組み立て。suite は操作ごとに分かれているが、
/// 撃つ相手 (argv を記録する stub と、そこへ繋いだ `TmuxRunner`) はどれも同じである。
protocol TmuxSessionOperationsTestSupport {}

extension TmuxSessionOperationsTestSupport {
  var executableURL: URL { URL(fileURLWithPath: "/test/bin/tmux") }
  var prefix: [String] { ["-u", "-L", "awt-test"] }
  /// `#` を含むのは、`-c` の値の format 展開への対処を全 argv の検証と同じ場所で押さえるため。
  var workingDirectory: String { "/repo/wt/#feature-a" }
  var escapedWorkingDirectory: String { "/repo/wt/##feature-a" }
  var sessionID: String { tmuxStubSessionID }

  func sessionName(
    _ identityPath: String = "/repo/.git/worktrees/feature-a"
  ) throws -> TmuxSessionName {
    TmuxSessionName(identity: try #require(WorktreeIdentity(rawValue: identityPath)))
  }

  /// `killSession` の省略時は `kill-session` にも `rest` を返す。
  func createHandler(
    name: TmuxSessionName,
    newSessionStdout: String? = nil,
    killSession: TmuxSessionStubResult? = nil,
    rest: TmuxSessionStubResult = stubSuccess()
  ) -> TmuxSessionStubHandler {
    let stdout = newSessionStdout ?? "\(tmuxStubSessionID)\n"
    return { arguments in
      if arguments.contains("has-session") {
        return stubFailure(stderr: "can't find session: \(name.rawValue)\n")
      }
      if arguments.contains("new-session") { return stubSuccess(stdout: stdout) }
      if let killSession, arguments.contains("kill-session") { return killSession }
      return rest
    }
  }

  func tmuxFailure(_ stderr: String) -> TmuxSessionOperationError {
    .tmux(.commandFailed(exitCode: 1, stdout: "", stderr: stderr))
  }

  func makeOperations(
    _ stub: TmuxSessionRunnerStub,
    canEnterDirectory: @escaping @Sendable (String) -> Bool = { _ in true }
  ) throws -> TmuxSessionOperations {
    TmuxSessionOperations(runner: try testRunner(stub), canEnterDirectory: canEnterDirectory)
  }

  /// 作業ディレクトリの検査を注入せず、製品が使う述語をそのまま撃つ入口。
  func makeOperationsWithFileSystem(_ stub: TmuxSessionRunnerStub) throws -> TmuxSessionOperations {
    TmuxSessionOperations(runner: try testRunner(stub))
  }

  private func testRunner(_ stub: TmuxSessionRunnerStub) throws -> TmuxRunner {
    try TmuxRunner(
      socketName: "awt-test",
      processRunner: stub,
      executableCandidates: [executableURL],
      parentEnvironment: [:],
      isExecutableFile: { _ in true }
    )
  }
}

struct TmuxSessionStubInvocation: Sendable, Equatable {
  let arguments: [String]
}

actor TmuxSessionRunnerStub: ProcessRunning {
  private let handler: TmuxSessionStubHandler
  private(set) var invocations: [TmuxSessionStubInvocation] = []

  init(result: TmuxSessionStubResult) {
    self.handler = { _ in result }
  }

  init(handler: @escaping TmuxSessionStubHandler) {
    self.handler = handler
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(TmuxSessionStubInvocation(arguments: arguments))
    return try handler(arguments).get()
  }
}
