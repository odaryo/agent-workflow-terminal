import Adapters
import Foundation
import TerminalCore
import Testing

@Suite("設計書 §3.1 の session への1行コマンド入力")
struct TmuxSessionOperationsCommandLineTests: TmuxSessionOperationsTestSupport {
  @Test(
    "UTF-8 のバイトと末尾 CR を完全一致 target に1回で送る",
    arguments: [
      ("echo hi", "65 63 68 6f 20 68 69"),
      ("echo hi;", "65 63 68 6f 20 68 69 3b"),
      (";;;", "3b 3b 3b"),
      ("echo hi\\", "65 63 68 6f 20 68 69 5c"),
      ("echo hi\\;", "65 63 68 6f 20 68 69 5c 3b"),
      ("echo hi\\\\;", "65 63 68 6f 20 68 69 5c 5c 3b"),
      ("#{host} ##", "23 7b 68 6f 73 74 7d 20 23 23"),
      ("-n x", "2d 6e 20 78"),
      ("a ; b", "61 20 3b 20 62"),
      ("日本語", "e6 97 a5 e6 9c ac e8 aa 9e"),
      ("e\u{301}", "65 cc 81"),
      ("  x  ", "20 20 78 20 20"),
    ]
  )
  func typesExactBytes(commandLine: String, hexadecimalBytes: String) async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(result: stubSuccess())

    try await makeOperations(stub).typeCommandLine(commandLine, into: name)

    let bytes = hexadecimalBytes.split(separator: " ").map(String.init)
    #expect(
      await stub.invocations.map(\.arguments) == [
        prefix + ["send-keys", "-t", "=\(name.rawValue):", "-H"] + bytes + ["0d"]
      ])
  }

  @Test("空文字と空白だけの入力では tmux を呼ばない", arguments: ["", " ", "　 \u{a0}"])
  func rejectsEmptyCommandLine(commandLine: String) async throws {
    try await expectRejected(commandLine)
  }

  @Test(
    "Unicode Cc と行・段落区切りは先頭・途中・末尾のいずれでも tmux を呼ばない",
    arguments: (0...0x9f).compactMap { Unicode.Scalar($0) }.filter {
      $0.properties.generalCategory == .control
    } + ["\u{2028}", "\u{2029}"].compactMap { $0.unicodeScalars.first }
  )
  func rejectsControlCharacters(scalar: Unicode.Scalar) async throws {
    let character = String(scalar)
    for commandLine in [character + "echo x", "echo" + character + "x", "echo x" + character] {
      try await expectRejected(commandLine)
    }
  }

  @Test("送信が失敗したら元のエラーを返し、再送しない")
  func reportsFailureWithoutRetry() async throws {
    let stderr = "server exited unexpectedly\n"
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: stderr))
    let operations = try makeOperations(stub)

    await #expect(throws: tmuxFailure(stderr)) {
      try await operations.typeCommandLine("echo x", into: sessionName())
    }
    #expect(await stub.invocations.count == 1)
  }

  @Test("不在 session は sessionNotFound にする")
  func reportsMissingSession() async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(
      result: stubFailure(stderr: "can't find session: \(name.rawValue)\n"))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
      try await operations.typeCommandLine("echo x", into: name)
    }
    #expect(await stub.invocations.count == 1)
  }

  @Test(
    "server 停止と socket 欠落を既存の分類で返す",
    arguments: [
      (tmuxServerNotRunningStderr, TmuxSessionOperationError.serverNotRunning),
      (
        tmuxServerSocketMissingStderr,
        TmuxSessionOperationError.serverSocketMissing(socketPath: "/private/tmp/tmux-501/default")
      ),
    ]
  )
  func reportsServerFailure(
    failure: (String, TmuxSessionOperationError)
  ) async throws {
    let stub = TmuxSessionRunnerStub(result: stubFailure(stderr: failure.0))
    let operations = try makeOperations(stub)

    await #expect(throws: failure.1) {
      try await operations.typeCommandLine("echo x", into: sessionName())
    }
    #expect(await stub.invocations.count == 1)
  }

  private func expectRejected(_ commandLine: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.invalidCommandLine(commandLine)) {
      try await operations.typeCommandLine(commandLine, into: sessionName())
    }
    #expect(await stub.invocations.isEmpty)
  }
}
