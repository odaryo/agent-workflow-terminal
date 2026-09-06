import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("worktree の tmux pane 一覧")
struct TmuxWorktreePaneSourceTests {
  @Test("導出した session を完全一致で指定し list-panes の順序を保つ")
  func listsPanesInTmuxOrder() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature"))
    let session = TmuxSessionName(identity: worktree)
    let output = try fixture("tmux-3.4-list-panes-dead.txt")
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: output, stderr: ""))
    let source = TmuxWorktreePaneSource(runner: try runner(spy))

    let panes = try await source.panes(of: worktree)

    let invocation = try #require(await spy.invocations.first)
    #expect(
      invocation == [
        "-u", "-L", "pane-source-test", "list-panes", "-s", "-t", "=\(session.rawValue)",
        "-F", TmuxListPanes.format,
      ])
    #expect(panes == TmuxListPanes.parse(output: output).panes.map(\.snapshot))
  }

  @Test("tmux 3.4 が session 不在を報告した場合は空配列を返す")
  func mapsMissingSessionToEmpty() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/missing"))
    let session = TmuxSessionName(identity: worktree)
    let spy = WorktreePaneProcessSpy(
      result: .init(
        exitCode: 1, stdout: "", stderr: "can't find window: \(session.rawValue)\n"))

    let panes = try await TmuxWorktreePaneSource(runner: try runner(spy)).panes(of: worktree)

    #expect(panes.isEmpty)
  }

  @Test("session 不在以外の失敗は捨てない")
  func preservesOtherFailures() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/failure"))
    let failure = TmuxRunnerError.commandFailed(exitCode: 1, stdout: "partial", stderr: "other\n")
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 1, stdout: "partial", stderr: "other\n"))

    await #expect(throws: TmuxWorktreePaneSourceError.tmux(failure)) {
      try await TmuxWorktreePaneSource(runner: try runner(spy)).panes(of: worktree)
    }
  }

  @Test("壊れた行があっても成功した pane を返す")
  func preservesPartialParseSuccess() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/partial"))
    let valid = try fixture("tmux-3.4-list-panes-dead.txt")
    let output = "broken\n" + valid
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: output, stderr: ""))

    let panes = try await TmuxWorktreePaneSource(runner: try runner(spy)).panes(of: worktree)

    #expect(panes == TmuxListPanes.parse(output: valid).panes.map(\.snapshot))
  }

  private func runner(_ processRunner: some ProcessRunning) throws -> TmuxRunner {
    try TmuxRunner(
      socketName: "pane-source-test", processRunner: processRunner,
      executableCandidates: [URL(fileURLWithPath: "/tmux")], parentEnvironment: [:],
      isExecutableFile: { _ in true })
  }

  private func fixture(_ name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
  }
}

private actor WorktreePaneProcessSpy: ProcessRunning {
  private(set) var invocations: [[String]] = []
  private let result: ProcessRunResult

  init(result: ProcessRunResult) {
    self.result = result
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    return result
  }
}
