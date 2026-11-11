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
        "-u", "-L", "pane-source-test", "list-panes", "-a", "-F",
        TmuxListPanes.formatWithSummary,
      ])
    #expect(panes == TmuxListPanes.parseWithSummary(output: output).panes.map(\.snapshot))
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

  /// `exit-empty off` の server で session が0個のとき、`list-panes -a` はこの形で失敗する
  /// (tmux 3.4 と 3.8 で実測、#781)。server は生きているので `isServerAbsent` とは別の分岐になる。
  @Test("server はいるが session が無い (no current target) は空配列にする")
  func mapsNoCurrentTargetToEmpty() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/missing"))
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 1, stdout: "", stderr: "no current target\n"))

    #expect(try await makeSource(spy).panes(of: worktree).isEmpty)
  }

  @Test("no current target でも exit 1 でなければ失敗を捨てない")
  func preservesNoCurrentTargetWithOtherExitCode() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/failure"))
    let failure = TmuxRunnerError.commandFailed(
      exitCode: 2, stdout: "", stderr: "no current target\n")
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 2, stdout: "", stderr: "no current target\n"))
    let source = try makeSource(spy)

    await #expect(throws: TmuxWorktreePaneSourceError.tmux(failure)) {
      try await source.panes(of: worktree)
    }
  }

  @Test(
    "stderr が no current target と完全一致しなければ失敗を捨てない",
    arguments: [
      "no current target: x\n", "error: no current target\n", "no current target\nother\n",
    ])
  func preservesNoCurrentTargetVariants(stderr: String) async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/failure"))
    let failure = TmuxRunnerError.commandFailed(exitCode: 1, stdout: "", stderr: stderr)
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 1, stdout: "", stderr: stderr))
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

    #expect(panes == TmuxListPanes.parseWithSummary(output: valid).panes.map(\.snapshot))
  }

  @Test("全行不正は行数だけのエラーにし、元の行を露出しない", arguments: [1, 3])
  func rejectsEntirelyUnparsableOutput(lineCount: Int) async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/invalid"))
    let lines = (0..<lineCount).map { "/private/project-\($0) confidential-title-\($0)" }
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: ""))
    let source = try makeSource(spy)

    do {
      _ = try await source.panes(of: worktree)
      Issue.record("全行不正の一覧を成功として返した")
    } catch {
      #expect(error == .unparsableOutput(failedLineCount: lineCount))
      let description = String(describing: error)
      for line in lines {
        #expect(!description.contains(line))
        for value in line.split(separator: " ") {
          #expect(!description.contains(value))
        }
      }
    }
  }

  @Test("空の出力は空配列にする")
  func mapsEmptyOutputToEmpty() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/empty"))
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: "", stderr: ""))

    #expect(try await makeSource(spy).panes(of: worktree).isEmpty)
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

  @Test("s3: list-panes を読み終えた時刻を snapshot の listedAt に入れる (設計書 §12.4.2)")
  func stampsSnapshotsWithListedAt() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature"))
    let output = try fixture(session: TmuxSessionName(identity: worktree).rawValue)
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: output, stderr: ""))
    let clock = ManualTimeSource()
    let source = try makeSource(spy, clock: clock)
    let listedAt = clock.now

    let panes = try await source.panes(of: worktree)
    let readings = try await source.summaryReadings(of: worktree)

    #expect(panes.map(\.listedAt) == [listedAt])
    #expect(readings.map(\.pane.listedAt) == [listedAt])
  }

  @Test("s4: TTL の内側で返したキャッシュの snapshot は最初に読んだ時刻のままにする")
  func cachedSnapshotsKeepFirstListedAt() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature"))
    let output = try fixture(session: TmuxSessionName(identity: worktree).rawValue)
    let spy = WorktreePaneProcessSpy(result: .init(exitCode: 0, stdout: output, stderr: ""))
    let clock = ManualTimeSource()
    let source = try makeSource(spy, clock: clock)
    let listedAt = clock.now
    _ = try await source.panes(of: worktree)

    clock.advance(by: .milliseconds(500))
    let cached = try await source.panes(of: worktree)

    #expect(await spy.invocations.count == 1)
    #expect(cached.map(\.listedAt) == [listedAt])
  }

  @Test("s8: listedAt は list-panes を読み終えた時刻にし、TTL は読み始めた時刻から数える")
  func listedAtIsReadCompletionTime() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature"))
    let output = try fixture(session: TmuxSessionName(identity: worktree).rawValue)
    let clock = ManualTimeSource()
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: output, stderr: ""),
      duringRun: { clock.advance(by: .milliseconds(300)) })
    let source = try makeSource(spy, clock: clock)
    let startedAt = clock.now

    let panes = try await source.panes(of: worktree)

    #expect(panes.map(\.listedAt) == [startedAt.advanced(by: .milliseconds(300))])
    // 読み終えてから 1s 経っていないが、読み始めてからは TTL (1s) を過ぎている。
    clock.advance(by: .milliseconds(800))
    _ = try await source.panes(of: worktree)
    #expect(await spy.invocations.count == 2)
  }

  @Test("s9: list-panes の失敗も、TTL は読み始めた時刻から数える")
  func failureTimeToLiveStartsAtReadStart() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/failure"))
    let clock = ManualTimeSource()
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 1, stdout: "partial", stderr: "other\n"),
      duringRun: { clock.advance(by: .milliseconds(1500)) })
    let source = try makeSource(spy, clock: clock)

    await #expect(
      throws: TmuxWorktreePaneSourceError.tmux(
        TmuxRunnerError.commandFailed(exitCode: 1, stdout: "partial", stderr: "other\n"))
    ) {
      try await source.panes(of: worktree)
    }
    // 読み終えてからは TTL 内だが、読み始めてからは TTL (1s) を過ぎている。
    await #expect(
      throws: TmuxWorktreePaneSourceError.tmux(
        TmuxRunnerError.commandFailed(exitCode: 1, stdout: "partial", stderr: "other\n"))
    ) {
      try await source.panes(of: worktree)
    }
    #expect(await spy.invocations.count == 2)
  }

  @Test("番号ごとに、その番号の session の pane だけを返す (設計書 §12.2)")
  func selectsPanesBySessionKey() async throws {
    let sessions = try SessionsOfTwoWorktrees()
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: try mixedOutput(sessions), stderr: ""))
    let source = try makeSource(spy)

    #expect(try await source.panes(of: sessions.first).map(\.id.rawValue) == ["%11", "%12"])
    #expect(try await source.panes(of: sessions.second).map(\.id.rawValue) == ["%21", "%22"])
    #expect(try await source.panes(of: sessions.otherFirst).map(\.id.rawValue) == ["%31"])
    #expect(try await source.panes(of: sessions.otherSecond).map(\.id.rawValue) == ["%41"])
    #expect(try await source.panes(of: sessions.twentieth).map(\.id.rawValue) == ["%29"])
  }

  @Test("worktree を渡すと番号 1 の session と同じ pane を返す")
  func worktreePanesMatchPrimarySession() async throws {
    let sessions = try SessionsOfTwoWorktrees()
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: try mixedOutput(sessions), stderr: ""))
    let source = try makeSource(spy)

    let byWorktree = try await source.panes(of: sessions.worktree)

    #expect(byWorktree == (try await source.panes(of: sessions.first)))
    #expect(byWorktree.map(\.id.rawValue) == ["%11", "%12"])
  }

  @Test("概要も番号ごとに、その番号の session の pane だけを返す")
  func selectsSummaryReadingsBySessionKey() async throws {
    let sessions = try SessionsOfTwoWorktrees()
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: try mixedOutput(sessions), stderr: ""))
    let source = try makeSource(spy)

    let first = try await source.summaryReadings(of: sessions.first)
    let second = try await source.summaryReadings(of: sessions.second)
    let otherFirst = try await source.summaryReadings(of: sessions.otherFirst)
    let byWorktree = try await source.summaryReadings(of: sessions.worktree)

    #expect(first.map(\.pane.id.rawValue) == ["%11", "%12"])
    #expect(second.map(\.pane.id.rawValue) == ["%21", "%22"])
    #expect(otherFirst.map(\.pane.id.rawValue) == ["%31"])
    #expect(byWorktree == first)
  }

  @Test("位置付きの概要も番号ごとに、その番号の session の pane だけを返す")
  func selectsLocatedSummaryReadingsBySessionKey() async throws {
    let sessions = try SessionsOfTwoWorktrees()
    let spy = WorktreePaneProcessSpy(
      result: .init(exitCode: 0, stdout: try mixedOutput(sessions), stderr: ""))
    let source = try makeSource(spy)

    let first = try await source.locatedSummaryReadings(of: sessions.first)
    let second = try await source.locatedSummaryReadings(of: sessions.second)
    let otherFirst = try await source.locatedSummaryReadings(of: sessions.otherFirst)
    let byWorktree = try await source.locatedSummaryReadings(of: sessions.worktree)

    #expect(first.map(\.readings.pane.id.rawValue) == ["%11", "%12"])
    #expect(second.map(\.readings.pane.id.rawValue) == ["%21", "%22"])
    #expect(otherFirst.map(\.readings.pane.id.rawValue) == ["%31"])
    #expect(byWorktree == first)
  }

  /// 同じ worktree の番号 1・2 と別の worktree の番号 1・2 を交互に並べ、番号 2 の名前に
  /// 前方一致する番号 20 の session も混ぜる。
  private func mixedOutput(_ sessions: SessionsOfTwoWorktrees) throws -> String {
    let rows: [(TerminalSessionKey, String)] = [
      (sessions.second, "%21"),
      (sessions.first, "%11"),
      (sessions.otherFirst, "%31"),
      (sessions.twentieth, "%29"),
      (sessions.otherSecond, "%41"),
      (sessions.first, "%12"),
      (sessions.second, "%22"),
    ]
    return try rows.map { key, paneID in
      try fixture(session: TmuxSessionName(key: key).rawValue, paneID: paneID)
    }
    .joined()
  }

  private func makeSource(_ spy: WorktreePaneProcessSpy) throws -> TmuxWorktreePaneSource {
    TmuxWorktreePaneSource(
      runner: try makeTmuxRunner(socketName: "pane-source-test", processRunner: spy))
  }

  private func makeSource(
    _ spy: WorktreePaneProcessSpy, clock: ManualTimeSource
  ) throws -> TmuxWorktreePaneSource {
    let runner = try makeTmuxRunner(socketName: "pane-source-test", processRunner: spy)
    return TmuxWorktreePaneSource(
      runner: runner,
      paneList: TmuxAllSessionPaneListCache(
        runner: runner, timeToLive: TmuxAllSessionPaneListCache.defaultTimeToLive,
        timeSource: clock))
  }

  /// `formatWithSummary` で採った fixture の先頭行 (pane `%0`) の session 名と pane ID だけを
  /// 差し替える。`\037` 区切りの1行で、session 名は行内に1度、pane ID は行頭にだけ現れる。
  private func fixture(session: String, paneID: String = "%11") throws -> String {
    let url = try #require(
      Bundle.module.url(
        forResource: "tmux-3.4-list-panes-summary-hostile.txt", withExtension: nil,
        subdirectory: "Fixtures"))
    let line = try #require(
      try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first)
    #expect(line.hasPrefix("%0\\037"))
    return paneID + line.dropFirst(2).replacingOccurrences(of: "summary-fixture", with: session)
      + "\n"
  }
}

private struct SessionsOfTwoWorktrees {
  let worktree: WorktreeIdentity
  let first: TerminalSessionKey
  let second: TerminalSessionKey
  let twentieth: TerminalSessionKey
  let otherFirst: TerminalSessionKey
  let otherSecond: TerminalSessionKey

  init() throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature"))
    let other = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/other"))
    self.worktree = worktree
    first = .primary(worktree)
    second = try #require(TerminalSessionKey(identity: worktree, index: 2))
    twentieth = try #require(TerminalSessionKey(identity: worktree, index: 20))
    otherFirst = .primary(other)
    otherSecond = try #require(TerminalSessionKey(identity: other, index: 2))
  }
}

private actor WorktreePaneProcessSpy: ProcessRunning {
  private(set) var invocations: [[String]] = []
  private let result: ProcessRunResult
  /// `list-panes` の実行中に時計を進める。読み始めと読み終えの時刻を分けるため。
  private let duringRun: @Sendable () -> Void

  init(result: ProcessRunResult, duringRun: @escaping @Sendable () -> Void = {}) {
    self.result = result
    self.duringRun = duringRun
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    duringRun()
    return result
  }
}
