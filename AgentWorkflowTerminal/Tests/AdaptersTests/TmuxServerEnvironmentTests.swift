import Foundation
import Testing

@testable import Adapters

@Suite("設計書 §4.1: UI 確認の tmux server 解決 (#535)")
struct TmuxServerEnvironmentTests {
  @Test(
    "未指定と空文字だけが既定 server になり、隔離できない値は原文を保持して拒否する",
    arguments: [
      (nil, .server(.userDefault)),
      ("", .server(.userDefault)),
      ("awt-ui-verify", .server(.socketName("awt-ui-verify"))),
      ("a.b_c-1", .server(.socketName("a.b_c-1"))),
      ("AZaz09._-", .server(.socketName("AZaz09._-"))),
      ("a", .server(.socketName("a"))),
      ("default", .invalid(value: "default")),
      (".", .invalid(value: ".")),
      ("..", .invalid(value: "..")),
      ("a/b", .invalid(value: "a/b")),
      ("a b", .invalid(value: "a b")),
      ("a\tb", .invalid(value: "a\tb")),
      ("a\nb", .invalid(value: "a\nb")),
      ("日本", .invalid(value: "日本")),
      ("a:b", .invalid(value: "a:b")),
      (String(repeating: "a", count: 64), .server(.socketName(String(repeating: "a", count: 64)))),
      (String(repeating: "a", count: 65), .invalid(value: String(repeating: "a", count: 65))),
    ] as [(String?, TmuxServerEnvironment.Resolution)]
  )
  func resolvesSocketName(value: String?, expected: TmuxServerEnvironment.Resolution) {
    var environment: [String: String] = [:]
    environment["AWT_TMUX_SOCKET_NAME"] = value

    #expect(TmuxServerEnvironment.socketNameKey == "AWT_TMUX_SOCKET_NAME")
    #expect(TmuxServerEnvironment.resolve(environment: environment) == expected)
  }

  @Test("解決した専用 socket が runner の global option へ引き継がれる")
  func resolvedSocketNameScopesRunnerArguments() throws {
    let name = "awt-ui-verify"
    let resolution = TmuxServerEnvironment.resolve(environment: ["AWT_TMUX_SOCKET_NAME": name])
    guard case .server(let server) = resolution else {
      Issue.record("有効な socket 名が拒否された: \(resolution)")
      return
    }
    let runner = try TmuxRunner(
      server: server,
      processRunner: UnexpectedProcessRunner(),
      executableCandidates: [URL(fileURLWithPath: "/test/bin/tmux")],
      parentEnvironment: [:],
      isExecutableFile: { _ in true }
    )

    #expect(runner.serverScopedArguments([]) == ["-u", "-L", name])
  }
}

private struct UnexpectedProcessRunner: ProcessRunning {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    Issue.record("server の解決と引数の組み立てではプロセスを起動しない")
    return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
  }
}
