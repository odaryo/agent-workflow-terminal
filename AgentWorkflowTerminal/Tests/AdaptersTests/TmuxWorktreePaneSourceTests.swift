import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("worktree の tmux pane 一覧")
struct TmuxWorktreePaneSourceTests {
  @Test("全 session を1回で取り、list-panes の順序を保つ")
  func listsPanesInTmuxOrder() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature"))
    let session = TmuxSessionName(identity: worktree)
    let output = try fixture(session: session.rawValue)
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: output, stderr: ""))
    let source = try makeSource(spy)

    let panes = try await source.panes(of: worktree)

    let invocation = try #require(await spy.invocations.first)
    #expect(
      invocation == [
        "-u", "-L", "pane-source-test", "list-panes", "-a", "-F", TmuxListPanes.format,
      ])
    #expect(panes == TmuxListPanes.parse(output: output).panes.map(\.snapshot))
  }

  /// `-a` は対象 server の全 session を返すので、ユーザー自身の session の pane が必ず混ざる。
  @Test("session 名が完全一致した pane だけを返す")
  func selectsPanesByExactSessionName() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature"))
    let session = TmuxSessionName(identity: worktree)
    // 前方一致・部分一致で拾えてしまう名前を並べる。
    let output =
      try fixture(session: session.rawValue)
      + (try fixture(session: session.rawValue + "-2", paneID: "%12"))
      + (try fixture(session: String(session.rawValue.dropLast()), paneID: "%13"))
      + (try fixture(session: "user-session", paneID: "%14"))
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: output, stderr: ""))

    let panes = try await makeSource(spy).panes(of: worktree)

    #expect(panes.map(\.id) == [PaneID(rawValue: "%11")])
  }

  @Test("session が無ければ空配列を返す")
  func mapsMissingSessionToEmpty() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/missing"))
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: try fixture(session: "other"), stderr: ""))

    #expect(try await makeSource(spy).panes(of: worktree).isEmpty)
  }

  @Test("server 不在は空配列にする")
  func mapsAbsentServerToEmpty() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/missing"))
    let spy = WorktreePaneProcessSpy(
      result: .init(
        exitCode: 1, stdout: "",
        stderr: "no server running on /private/tmp/tmux-501/pane-source-test\n"))

    #expect(try await makeSource(spy).panes(of: worktree).isEmpty)
  }

  @Test("session 不在以外の失敗は捨てない")
  func preservesOtherFailures() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/failure"))
    let failure = TmuxRunnerError.commandFailed(exitCode: 1, stdout: "partial", stderr: "other\n")
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 1, stdout: "partial", stderr: "other\n"))
    let source = try makeSource(spy)

    await #expect(throws: TmuxWorktreePaneSourceError.tmux(failure)) {
      try await source.panes(of: worktree)
    }
  }

  @Test("壊れた行があっても成功した pane を返す")
  func preservesPartialParseSuccess() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/partial"))
    let session = TmuxSessionName(identity: worktree)
    let valid = try fixture(session: session.rawValue)
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: "broken\n" + valid, stderr: ""))

    let panes = try await makeSource(spy).panes(of: worktree)

    #expect(panes == TmuxListPanes.parse(output: valid).panes.map(\.snapshot))
  }

  @Test("TTL の内側なら worktree が違っても list-panes は1回だけ起動する")
  func sharesOneLaunchAcrossWorktrees() async throws {
    let worktrees = try (0..<5).map {
      try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/w\($0)"))
    }
    let output = try worktrees.enumerated()
      .map { try fixture(session: TmuxSessionName(identity: $1).rawValue, paneID: "%2\($0)") }
      .joined()
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: output, stderr: ""))
    let clock = ManualTimeSource()
    let runner = try makeTmuxRunner(socketName: "pane-source-test", processRunner: spy)
    let source = TmuxWorktreePaneSource(
      runner: runner,
      paneList: TmuxAllSessionPaneListCache(
        runner: runner, timeToLive: TmuxAllSessionPaneListCache.defaultTimeToLive,
        timeSource: clock))

    var identifiers: [PaneID] = []
    for worktree in worktrees {
      identifiers.append(contentsOf: try await source.panes(of: worktree).map(\.id))
    }
    #expect(await spy.invocations.count == 1)

    clock.advance(by: .seconds(2))
    _ = try await source.panes(of: worktrees[0])
    #expect(await spy.invocations.count == 2)
    #expect(identifiers == (0..<5).map { PaneID(rawValue: "%2\($0)") })
  }

  private func makeSource(_ spy: WorktreePaneProcessSpy) throws -> TmuxWorktreePaneSource {
    TmuxWorktreePaneSource(
      runner: try makeTmuxRunner(socketName: "pane-source-test", processRunner: spy))
  }

  /// fixture の session 名と pane ID だけを差し替える。`\037` 区切りの1行なので、
  /// 置換対象はどちらも行内に1度しか現れない。
  private func fixture(session: String, paneID: String = "%11") throws -> String {
    let url = try #require(
      Bundle.module.url(
        forResource: "tmux-3.4-list-panes-dead.txt", withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
      .replacingOccurrences(of: "dead-r3", with: session)
      .replacingOccurrences(of: "%11", with: paneID)
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
