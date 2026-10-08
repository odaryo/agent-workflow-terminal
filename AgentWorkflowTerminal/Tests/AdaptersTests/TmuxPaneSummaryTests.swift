import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("pane 連携変数の list-panes 読み取り (設計書 §12.7)")
struct TmuxListPanesSummaryTests {
  @Test("連携変数のフィールドは長さ・LF/0x1F・UTF-8 の順に判定し、旗の後ろに二重化した値を出す")
  func formatAppendsSummaryFields() {
    // tmux へ渡す format と1文字も違わないことの検証。組み立てを再実装しないよう原文で置く。
    // swiftlint:disable line_length
    let fields = [
      "#{?#{e|>|:#{n:@awt_status},1024},X,#{?#{m:*[\n\r\u{1F}]*,#{@awt_status}},L,#{?#{m/r:^.*$,#{@awt_status}},v#{s/\\\\/\\\\\\\\/:@awt_status},U}}}",
      "#{?#{e|>|:#{n:@awt_done},1024},X,#{?#{m:*[\n\r\u{1F}]*,#{@awt_done}},L,#{?#{m/r:^.*$,#{@awt_done}},v#{s/\\\\/\\\\\\\\/:@awt_done},U}}}",
      "#{?#{e|>|:#{n:@awt_purpose},1024},X,#{?#{m:*[\n\r\u{1F}]*,#{@awt_purpose}},L,#{?#{m/r:^.*$,#{@awt_purpose}},v#{s/\\\\/\\\\\\\\/:@awt_purpose},U}}}",
    ]
    // swiftlint:enable line_length
    #expect(
      TmuxListPanes.formatWithSummary
        == ([TmuxListPanes.format] + fields).joined(separator: "\u{1F}"))
  }

  // 採取: tmux 3.4 (/opt/homebrew/bin/tmux) と tmux 3.7c (homebrew bottle
  // `tmux--3.7c.arm64_tahoe.bottle.1.tar.gz` を /private/tmp/awt188-tmux37c へ隔離展開し、
  // 依存 dylib を同じ場所へ展開した utf8proc 2.12.0 / libevent 2.1.13 / jemalloc 5.4.0 へ
  // `install_name_tool` で付け替えたもの)。両版とも同じ手順:
  // `tmux -L <一意名> -f /dev/null new-session -d -s summary-fixture -x 200 -y 50 -c /private/tmp 'sleep 300'`
  // に `split-window -d` を4回 (`select-layout tiled`) し、全 pane を `select-pane -T fixture-title`。
  // pane 一覧の順 (%0 %4 %3 %2 %1) の先頭4つへ `set-option -p -t <pane>` で次を書き、
  // `LC_ALL=C tmux -u -L <一意名> list-panes -a -F "$formatWithSummary"` を保存した。
  //   %0: @awt_status '4242 設計｜相談中' / @awt_done '4242 1700000000' /
  //       @awt_purpose 'ログイン不具合を修正する'
  //   %4: @awt_status '4242 a\b|c$d\037e\' (backslash は実バイト) / @awt_purpose "1行目<LF>2行目"
  //   %3: @awt_status "4242 1行目<LF>2行目" / @awt_done "4242 a<0x1F>b" /
  //       @awt_purpose "<0xFF>\037x\" (不正 UTF-8 + backslash)
  //   %2: @awt_status "4242 " + 'x'×1020 (1025 バイト) / @awt_done "4242 <ESC>[31mred" /
  //       @awt_purpose '' (空文字を set)
  //   %1: 何も書かない
  //   %5: 別 window (`new-window -d`) に作り、`list-panes -a` の最後の行にする。
  //       @awt_status "4242 a<CR>b" / @awt_purpose "4242 x<CR>" (最後の行の最後のフィールドが CR で終わる)
  @Test(
    "LF・CR・0x1F・backslash・不正 UTF-8 を含む値があっても全 pane を観測でき、失敗行も出ない",
    arguments: [
      "tmux-3.4-list-panes-summary-hostile.txt", "tmux-3.7c-list-panes-summary-hostile.txt",
    ])
  func parsesHostileSummaryFixture(name: String) throws {
    let result = TmuxListPanes.parseWithSummary(output: try fixture(named: name))

    // CR を `L` で落とさないと、3.7c では %5 の行末が `\r\n` になって出力末尾の改行判定が外れ、
    // 空の行が failure として1件増えた (実測)。
    #expect(result.failures.isEmpty)
    #expect(result.panes.map(\.paneID.rawValue) == ["%0", "%4", "%3", "%2", "%1", "%5"])
    // 連携変数の値に引きずられず、pane 自体のフィールドは全 pane で読めている。
    #expect(result.panes.allSatisfy { $0.sessionName == "summary-fixture" })
    #expect(result.panes.allSatisfy { $0.title == "fixture-title" })
    #expect(result.panes.allSatisfy { $0.currentPath == "/private/tmp" })

    let readings = Dictionary(
      uniqueKeysWithValues: result.panes.map { ($0.paneID.rawValue, $0.summaryReadings) })
    #expect(
      readings["%0"]
        == PaneSummaryReadings(
          status: .value("4242 設計｜相談中"), completion: .value("4242 1700000000"),
          purpose: .value("ログイン不具合を修正する")))
    #expect(
      readings["%4"]
        == PaneSummaryReadings(
          status: .value(#"4242 a\b|c$d\037e\"#), completion: .value(""),
          purpose: .unreadable(.containsLineBreakOrUnitSeparator)))
    #expect(
      readings["%3"]
        == PaneSummaryReadings(
          status: .unreadable(.containsLineBreakOrUnitSeparator),
          completion: .unreadable(.containsLineBreakOrUnitSeparator),
          purpose: .unreadable(.invalidUTF8)))
    #expect(
      readings["%2"]
        == PaneSummaryReadings(
          status: .unreadable(.tooLong), completion: .value("4242 \u{1B}[31mred"),
          purpose: .value("")))
    #expect(
      readings["%1"]
        == PaneSummaryReadings(status: .value(""), completion: .value(""), purpose: .value("")))
    #expect(
      readings["%5"]
        == PaneSummaryReadings(
          status: .unreadable(.containsLineBreakOrUnitSeparator), completion: .value(""),
          purpose: .unreadable(.containsLineBreakOrUnitSeparator)))
  }

  @Test("pane 用の format で読んだ行には連携変数が無い")
  func plainFormatHasNoSummary() throws {
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-dead.txt"))
    #expect(result.panes.count == 1)
    #expect(result.panes.allSatisfy { $0.summaryReadings == nil })
  }

  @Test("2つの format は互いの行を受け付けない")
  func formatsDoNotAcceptEachOther() throws {
    let summaryOutput = try fixture(named: "tmux-3.4-list-panes-summary-hostile.txt")
    let plainOutput = try fixture(named: "tmux-3.4-list-panes-dead.txt")

    #expect(TmuxListPanes.parse(output: summaryOutput).panes.isEmpty)
    #expect(
      TmuxListPanes.parse(output: summaryOutput).failures.map(\.error)
        == Array(repeating: .invalidFieldCount(actual: 17), count: 6))
    #expect(
      TmuxListPanes.parseWithSummary(output: plainOutput).failures.map(\.error)
        == [.invalidFieldCount(actual: 14)])
  }

  @Test(
    "連携変数のフィールドを値へ戻せないときは、その変数だけを読めなかったことにする",
    arguments: [
      ("", PaneUserOptionReading.unreadable(.malformedOutput)),
      ("Z", .unreadable(.malformedOutput)),
      ("XX", .unreadable(.malformedOutput)),
      (#"va\"#, .unreadable(.malformedOutput)),
      (#"va\nb"#, .unreadable(.malformedOutput)),
      (#"va\\b\$c\033d"#, .value("a\\b$c\u{1B}d")),
    ])
  func decodesSummaryFieldIndependently(field: String, expected: PaneUserOptionReading) throws {
    let line = try #require(
      try fixture(named: "tmux-3.4-list-panes-summary-hostile.txt").split(separator: "\n").first)
    // 先頭行の最後のフィールド (@awt_purpose) だけを差し替える。他は実 tmux の出力のまま。
    let prefix = try #require(line.range(of: #"\037v"#, options: .backwards)).lowerBound
    let pane = try TmuxListPanes.parseWithSummary(line: line[..<prefix] + #"\037"# + field)

    #expect(pane.paneID == PaneID(rawValue: "%0"))
    #expect(pane.summaryReadings?.status == .value("4242 設計｜相談中"))
    #expect(pane.summaryReadings?.purpose == expected)
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}

@Suite("pane の現在の Agent プロセス (設計書 §12.7)")
struct PaneAgentProcessTests {
  private static let names: Set<String> = ["claude", "codex"]

  /// `ps -Ao pid=,ppid=,comm=` と同じ形の出力から作る。
  private func table(_ output: String) -> ProcessTableSnapshot {
    ProcessTableSnapshot.parse(output)
  }

  @Test("根に最も近い Agent 名のプロセスを選ぶ (子孫に同名が居ても根に近い方)")
  func choosesNearestToRoot() {
    let snapshot = table("100 1 zsh\n200 100 claude\n300 200 zsh\n400 300 claude\n")
    #expect(snapshot.nearestProcessIDs(named: Self.names, inTreeOf: 100) == [200])
  }

  @Test("pane の根そのものが Agent なら根を選ぶ")
  func rootItselfCanBeTheAgent() {
    let snapshot = table("100 1 codex\n200 100 claude\n")
    #expect(snapshot.nearestProcessIDs(named: Self.names, inTreeOf: 100) == [100])
  }

  @Test("同じ深さに複数あれば全部返す")
  func returnsAllAtTheShallowestDepth() {
    let snapshot = table("100 1 zsh\n300 100 codex\n200 100 claude\n400 200 claude\n")
    #expect(snapshot.nearestProcessIDs(named: Self.names, inTreeOf: 100) == [200, 300])
  }

  @Test("別の pane の木にある Agent は拾わない")
  func ignoresOtherTrees() {
    let snapshot = table("100 1 zsh\n200 1 zsh\n300 200 claude\n")
    #expect(snapshot.nearestProcessIDs(named: Self.names, inTreeOf: 100).isEmpty)
    #expect(snapshot.nearestProcessIDs(named: Self.names, inTreeOf: 999).isEmpty)
  }

  @Test(
    "共有の ps スナップショットから現在の Agent プロセスを決める",
    arguments: [
      ("100 1 zsh\n200 100 /opt/tools/claude\n", PaneAgentProcess.identified(processID: 200)),
      ("100 1 zsh\n200 100 sleep\n", .notRunning),
      ("100 1 zsh\n200 100 claude\n300 100 codex\n", .ambiguous(processIDs: [200, 300])),
    ])
  func resolvesFromSharedSnapshot(
    processTable: String, expected: PaneAgentProcess
  ) async throws {
    let spy = ObservationProcessSpy(processTableOutput: processTable)
    let source = TmuxAgentSignalSource(
      processTable: ProcessTableSnapshotCache(
        processRunner: spy, executableURL: URL(fileURLWithPath: "/ps")),
      screenBatcher: TmuxPaneScreenBatcher(
        runner: try makeTmuxRunner(socketName: "agent-process", processRunner: spy)))
    let pane = makePaneSnapshot(id: "%1", pid: 100)

    let agent = await source.agentProcess(for: pane, matchingProcessNames: Self.names)
    let liveness = await source.liveness(for: pane, matchingProcessNames: Self.names)

    #expect(agent == expected)
    // 生存確認と同じ1回の `ps` を使う。
    #expect(liveness != .undetermined)
    #expect(await spy.count(of: .ps) == 1)
  }

  @Test("dead pane は Agent が居ないとして扱い、ps を見に行かない")
  func deadPaneHasNoAgent() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "100 1 claude\n")
    let source = TmuxAgentSignalSource(
      processTable: ProcessTableSnapshotCache(
        processRunner: spy, executableURL: URL(fileURLWithPath: "/ps")),
      screenBatcher: TmuxPaneScreenBatcher(
        runner: try makeTmuxRunner(socketName: "agent-process", processRunner: spy)))
    let pane = PaneSnapshot(
      id: PaneID(rawValue: "%1"), processID: 100, tty: "", currentCommand: "",
      currentPath: "", title: "", termination: .exited(status: 0))

    #expect(await source.agentProcess(for: pane, matchingProcessNames: Self.names) == .notRunning)
    #expect(await spy.count(of: .ps) == 0)
  }

  @Test("ps を読めなければ特定できない")
  func unreadableProcessTableIsUnobservable() async throws {
    let source = TmuxAgentSignalSource(
      processTable: ProcessTableSnapshotCache(
        processRunner: FailingProcessRunner(), executableURL: URL(fileURLWithPath: "/ps")),
      screenBatcher: TmuxPaneScreenBatcher(
        runner: try makeTmuxRunner(
          socketName: "agent-process", processRunner: FailingProcessRunner())))

    #expect(
      await source.agentProcess(
        for: makePaneSnapshot(id: "%1", pid: 100), matchingProcessNames: Self.names)
        == .unobservable)
  }
}

@Suite("pane 連携変数の共有読み取り (設計書 §12.7)")
struct TmuxWorktreePaneSourceSummaryTests {
  @Test("連携変数は pane 一覧と同じ1回の list-panes から読む")
  func sharesListPanesWithPaneList() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/summary"))
    let session = TmuxSessionName(identity: worktree).rawValue
    let output = try String(
      contentsOf: try #require(
        Bundle.module.url(
          forResource: "tmux-3.4-list-panes-summary-hostile.txt", withExtension: nil,
          subdirectory: "Fixtures")),
      encoding: .utf8
    ).replacingOccurrences(of: "summary-fixture", with: session)
    let spy = ObservationProcessSpy(listPanesOutput: output)
    let clock = ManualTimeSource()
    let runner = try makeTmuxRunner(socketName: "summary-test", processRunner: spy)
    let source = TmuxWorktreePaneSource(
      runner: runner,
      paneList: TmuxAllSessionPaneListCache(
        runner: runner, timeToLive: .seconds(1), timeSource: clock))

    let panes = try await source.panes(of: worktree)
    let summaries = try await source.summaryReadings(of: worktree)

    #expect(await spy.count(of: .listPanes) == 1)
    #expect(summaries.map(\.pane) == panes)
    #expect(summaries.first?.readings.status == .value("4242 設計｜相談中"))
    #expect(summaries.map(\.readings.purpose)[1] == .unreadable(.containsLineBreakOrUnitSeparator))
  }
}

@Suite("目的の書き込み (設計書 §12.7 / §13)")
struct TmuxPanePurposeWriterTests {
  private func makeWriter() throws -> (TmuxPanePurposeWriter, ObservationProcessSpy) {
    let spy = ObservationProcessSpy()
    return (
      TmuxPanePurposeWriter(
        runner: try makeTmuxRunner(socketName: "purpose-test", processRunner: spy)), spy
    )
  }

  @Test("pane option として書き、値が - で始まっても option に読ませない")
  func setsPaneOption() async throws {
    let (writer, spy) = try makeWriter()
    try await writer.setPurpose("-u ログイン修正", of: PaneID(rawValue: "%3"))

    #expect(
      await spy.invocations == [
        [
          "-u", "-L", "purpose-test", "set-option", "-p", "-t", "%3", "--", "@awt_purpose",
          "-u ログイン修正",
        ]
      ])
  }

  @Test("空文字・空白だけは削除 (-u) と同じにする", arguments: ["", "   ", "\u{3000}"])
  func blankClears(text: String) async throws {
    let (writer, spy) = try makeWriter()
    try await writer.setPurpose(text, of: PaneID(rawValue: "%3"))

    #expect(
      await spy.invocations == [
        ["-u", "-L", "purpose-test", "set-option", "-p", "-u", "-t", "%3", "@awt_purpose"]
      ])
  }

  @Test(
    "改行などの制御文字を含む入力は書かずに拒否する (1行へ正規化しない)",
    arguments: ["1行目\n2行目", "末尾改行\n", "a\tb", "a\u{1B}b"])
  func rejectsControlCharacters(text: String) async throws {
    let (writer, spy) = try makeWriter()
    await #expect(throws: TmuxPanePurposeWriterError.containsControlCharacter) {
      try await writer.setPurpose(text, of: PaneID(rawValue: "%3"))
    }
    #expect(await spy.invocations.isEmpty)
  }

  @Test("読み取り側が落とす長さは書かない")
  func rejectsTooLong() async throws {
    let (writer, spy) = try makeWriter()
    let atLimit = String(repeating: "あ", count: 341) + "a"  // 1024 バイト
    try await writer.setPurpose(atLimit, of: PaneID(rawValue: "%3"))
    await #expect(throws: TmuxPanePurposeWriterError.tooLong(byteCount: 1025, limit: 1024)) {
      try await writer.setPurpose(atLimit + "a", of: PaneID(rawValue: "%3"))
    }
    #expect(await spy.invocations.count == 1)
  }

  @Test("pane ID の形でない target は tmux へ渡さない", arguments: ["", "%", "%1a", "=sess", "1"])
  func rejectsMalformedPaneID(raw: String) async throws {
    let (writer, spy) = try makeWriter()
    await #expect(throws: TmuxPanePurposeWriterError.invalidPaneID(PaneID(rawValue: raw))) {
      try await writer.setPurpose("x", of: PaneID(rawValue: raw))
    }
    await #expect(throws: TmuxPanePurposeWriterError.invalidPaneID(PaneID(rawValue: raw))) {
      try await writer.clearPurpose(of: PaneID(rawValue: raw))
    }
    #expect(await spy.invocations.isEmpty)
  }
}

private struct FailingProcessRunner: ProcessRunning {
  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    ProcessRunResult(exitCode: 1, stdout: "", stderr: "failed\n")
  }
}
