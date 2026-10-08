import Adapters
import Foundation
import TerminalCore
import Testing

private let isPaneSummaryIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

/// 書き込み → `list-panes` → 解釈を実 tmux で通す (設計書 §12.7)。ハーネスの書き込みは
/// ハーネスと同じ `set-option -p` を外から打って代用する。
///
/// - Important: Agent プロセスは `/bin/sleep` への **symlink** を `claude` / `codex` の名前で
///   起こす (`InactivePaneObservationIntegrationTests` と同じ理由: 複製は SIGKILL される)。
///   書き込みに使う PID は**解決器とは独立に**得る — `claude` は pane のコマンドそのもので
///   `#{pane_pid}`、`codex` は親 shell の `$!` をファイルへ書かせる。解決器の出力を書き込みに
///   使うと、解決器が誤っていても一致して緑になる。
@Suite(
  "pane 連携変数の書き込みと解釈の統合 (設計書 §12.7)",
  .enabled(if: isPaneSummaryIntegrationEnabled)
)
struct TmuxPaneSummaryIntegrationTests {
  private static let agentNames: Set<String> = ["claude", "codex"]

  @Test("Agent 本人の PID で書いた値だけを受理し、Claude と Codex の pane で混ざらない")
  func acceptsOnlyTheCurrentAgentsValues() async throws {
    let workspace = try AgentWorkspace()
    defer { workspace.remove() }
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/summary-agents"))

    let socketName = uniqueSocketName("pane-summary")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let panes = try await workspace.startAgents(in: worktree, runner: runner)
      try await Self.set(
        TmuxPaneSummaryOption.status, "\(panes.claudePID) 設計｜相談中", panes.claude, runner)
      try await Self.set(
        TmuxPaneSummaryOption.completion, "\(panes.claudePID) turn-1", panes.claude, runner)
      // Codex の pane に Claude の PID で書いた現在地 (別 Agent の値) と、本人の PID の完了。
      try await Self.set(
        TmuxPaneSummaryOption.status, "\(panes.claudePID) 実装中", panes.codex, runner)
      try await Self.set(
        TmuxPaneSummaryOption.completion, "\(panes.codexPID) turn-9", panes.codex, runner)
      try await TmuxPanePurposeWriter(runner: runner).setPurpose("ログイン修正", of: panes.codex)

      let summaries = try await Self.interpret(worktree, runner: runner)

      let claude = try #require(summaries[panes.claude])
      #expect(claude.agent == .identified(processID: panes.claudePID))
      #expect(claude.summary.status == .accepted("設計｜相談中"))
      #expect(
        claude.summary.completion
          == .accepted(AgentStampedValue(agentProcessID: panes.claudePID, text: "turn-1")))
      #expect(claude.summary.purpose == .unset)

      let codex = try #require(summaries[panes.codex])
      // 親 shell の子にいる Agent を、根に最も近い Agent 名のプロセスとして特定できている。
      #expect(codex.agent == .identified(processID: panes.codexPID))
      #expect(
        codex.summary.status
          == .discarded(
            .agentProcessMismatch(written: panes.claudePID, current: panes.codexPID)))
      #expect(
        codex.summary.completion
          == .accepted(AgentStampedValue(agentProcessID: panes.codexPID, text: "turn-9")))
      // 目的は PID 照合をしない。
      #expect(codex.summary.purpose == .accepted("ログイン修正"))

      // Agent が終わると、書かれた値が pane option に残っていても受理しない。
      #expect(kill(panes.codexPID, SIGTERM) == 0)
      try await waitUntil {
        (try? await Self.interpret(worktree, runner: runner))?[panes.codex]?.agent == .notRunning
      }
      let afterExit = try #require(try await Self.interpret(worktree, runner: runner)[panes.codex])
      #expect(
        afterExit.summary.completion
          == .discarded(.agentProcessNotRunning(written: panes.codexPID)))
      #expect(afterExit.summary.purpose == .accepted("ログイン修正"))
    }
  }

  @Test("LF・0x1F・backslash・不正 UTF-8・長すぎる値は、その変数だけを落として他を壊さない")
  func hostileValuesStayInTheirOwnField() async throws {
    let workspace = try AgentWorkspace()
    defer { workspace.remove() }
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/summary-hostile"))

    let socketName = uniqueSocketName("pane-summary-hostile")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let session = TmuxSessionName(identity: worktree).rawValue
      let hostile = try await Self.newPane(session: session, runner: runner, createSession: true)
      let unitSeparator = try await Self.newPane(
        session: session, runner: runner, createSession: false)
      let plain = try await Self.newPane(session: session, runner: runner, createSession: false)
      let japaneseAtLimit = "4242 " + String(repeating: "あ", count: 339) + "aa"
      #expect(japaneseAtLimit.utf8.count == TmuxListPanes.summaryValueByteLimit)

      try await Self.set(TmuxPaneSummaryOption.status, "4242 1行目\n2行目", hostile, runner)
      try await Self.set(TmuxPaneSummaryOption.purpose, japaneseAtLimit + "a", hostile, runner)
      // 不正 UTF-8 は Swift の String (argv) に載らないので、設定ファイルの二重引用符の中の
      // 8進 escape (`\377`) で tmux 自身に 0xFF を作らせる。生の 0xFF を書いたファイルは
      // tmux の構文解析が拒否する (3.4 / 3.7c とも `too many arguments`。実測)。
      try await workspace.source(
        "set-option -p -t \(hostile.rawValue) @awt_done " + #""4242 \377\\037x\\""# + "\n",
        runner: runner)
      try await Self.set(TmuxPaneSummaryOption.completion, "4242 a\u{1F}b", unitSeparator, runner)
      try await Self.set(TmuxPaneSummaryOption.status, #"4242 a\b|c$d\037e\"#, plain, runner)
      try await Self.set(TmuxPaneSummaryOption.completion, japaneseAtLimit, plain, runner)
      try await Self.set(TmuxPaneSummaryOption.purpose, "#{pane_id},}## \u{1B}[31m", plain, runner)

      let readings = try await TmuxWorktreePaneSource(runner: runner).summaryReadings(of: worktree)
      let byPane = Dictionary(uniqueKeysWithValues: readings.map { ($0.pane.id, $0.readings) })

      #expect(Set(readings.map(\.pane.id)) == [hostile, unitSeparator, plain])
      #expect(
        byPane[hostile]
          == PaneSummaryReadings(
            status: .unreadable(.containsLineBreakOrUnitSeparator),
            completion: .unreadable(.invalidUTF8),
            purpose: .unreadable(.tooLong)))
      #expect(
        byPane[unitSeparator]
          == PaneSummaryReadings(
            status: .value(""), completion: .unreadable(.containsLineBreakOrUnitSeparator),
            purpose: .value("")))
      #expect(
        byPane[plain]
          == PaneSummaryReadings(
            status: .value(#"4242 a\b|c$d\037e\"#), completion: .value(japaneseAtLimit),
            purpose: .value("#{pane_id},}## \u{1B}[31m")))
    }
  }

  @Test("CR で終わる値が出力の最後の行にあっても、失敗行を出さずに全 pane を読む")
  func carriageReturnAtTheEndOfOutput() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/summary-cr"))

    let socketName = uniqueSocketName("pane-summary-cr")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let session = TmuxSessionName(identity: worktree).rawValue
      let first = try await Self.newPane(session: session, runner: runner, createSession: true)
      // 別 window の pane は `list-panes -a` で最後の行になる。その最後のフィールド
      // (@awt_purpose) を CR で終える — 3.7c は CR を生で出すので、落とさなければ行末が
      // `\r\n` になり、出力末尾の改行判定が外れて空の failure 行が1件増える (実測)。
      let output = try await runner.run(arguments: [
        "new-window", "-d", "-t", "=\(session):", "-P", "-F", "#{pane_id}", "/bin/sh",
      ])
      let last = PaneID(rawValue: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      try await Self.set(TmuxPaneSummaryOption.status, "4242 a\rb", first, runner)
      try await Self.set(TmuxPaneSummaryOption.status, "4242 a\rb", last, runner)
      try await Self.set(TmuxPaneSummaryOption.purpose, "4242 x\r", last, runner)

      // キャッシュを通さず、キャッシュと同じ argv の生出力を見る。
      let raw = try await runner.run(arguments: [
        "list-panes", "-a", "-F", TmuxListPanes.formatWithSummary,
      ]).stdout
      let result = TmuxListPanes.parseWithSummary(output: raw)

      #expect(!raw.utf8.contains(UInt8(ascii: "\r")))
      #expect(result.failures.isEmpty)
      #expect(result.panes.map(\.paneID).suffix(2) == [first, last])
      let readings = Dictionary(
        uniqueKeysWithValues: result.panes.map { ($0.paneID, $0.summaryReadings) })
      #expect(readings[first]??.status == .unreadable(.containsLineBreakOrUnitSeparator))
      #expect(
        readings[last]
          == PaneSummaryReadings(
            status: .unreadable(.containsLineBreakOrUnitSeparator), completion: .value(""),
            purpose: .unreadable(.containsLineBreakOrUnitSeparator)))
    }
  }

  @Test("目的は書いたとおりに読め、消すと未設定に戻る")
  func purposeRoundTrip() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/summary-purpose"))

    let socketName = uniqueSocketName("pane-summary-purpose")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let session = TmuxSessionName(identity: worktree).rawValue
      let pane = try await Self.newPane(session: session, runner: runner, createSession: true)
      let writer = TmuxPanePurposeWriter(runner: runner)
      let atLimit = String(repeating: "設", count: 341) + "a"  // 1024 バイト

      for text in [#"C:\work\設計 $HOME"#, "-u", "-x foo", "--", atLimit] {
        try await writer.setPurpose(text, of: pane)
        #expect(try await Self.readPurpose(worktree, pane: pane, runner: runner) == .accepted(text))
      }

      try await writer.setPurpose("  ", of: pane)
      #expect(try await Self.readPurpose(worktree, pane: pane, runner: runner) == .unset)
      // 未設定の pane に削除を重ねても失敗しない。
      try await writer.clearPurpose(of: pane)
      #expect(try await Self.readPurpose(worktree, pane: pane, runner: runner) == .unset)

      await #expect(throws: TmuxPanePurposeWriterError.self) {
        try await writer.setPurpose("x", of: PaneID(rawValue: "%999"))
      }
    }
  }

  // MARK: - helpers

  private struct Interpreted {
    let agent: PaneAgentProcess
    let summary: PaneSummary
  }

  /// 毎回新しい読み手を作る。キャッシュ (list-panes 1 秒 / ps 2.5 秒) を越えて、書き込み後の
  /// 状態を読むため。
  private static func interpret(
    _ worktree: WorktreeIdentity, runner: TmuxRunner
  ) async throws -> [PaneID: Interpreted] {
    let source = TmuxWorktreePaneSource(runner: runner)
    let signals = TmuxAgentSignalSource(
      tmuxRunner: runner, processRunner: FoundationProcessRunner())
    var result: [PaneID: Interpreted] = [:]
    for snapshot in try await source.summaryReadings(of: worktree) {
      let agent = await signals.agentProcess(
        for: snapshot.pane, matchingProcessNames: agentNames)
      result[snapshot.pane.id] = Interpreted(
        agent: agent,
        summary: PaneSummary(
          paneID: snapshot.pane.id, readings: snapshot.readings, agentProcess: agent))
    }
    return result
  }

  private static func readPurpose(
    _ worktree: WorktreeIdentity, pane: PaneID, runner: TmuxRunner
  ) async throws -> PaneSummaryEntry<String>? {
    let readings = try await TmuxWorktreePaneSource(runner: runner).summaryReadings(of: worktree)
    return readings.first { $0.pane.id == pane }.map {
      PaneSummary(paneID: pane, readings: $0.readings, agentProcess: .notRunning).purpose
    }
  }

  private static func set(
    _ option: String, _ value: String, _ pane: PaneID, _ runner: TmuxRunner
  ) async throws {
    _ = try await runner.run(arguments: ["set-option", "-p", "-t", pane.rawValue, option, value])
  }

  private static func newPane(
    session: String, runner: TmuxRunner, createSession: Bool
  ) async throws -> PaneID {
    let arguments =
      createSession
      ? [
        "new-session", "-d", "-s", session, "-x", "200", "-y", "50", "-P", "-F", "#{pane_id}",
        "/bin/sh",
      ]
      : ["split-window", "-d", "-t", "=\(session):", "-P", "-F", "#{pane_id}", "/bin/sh"]
    let output = try await runner.run(arguments: arguments)
    if !createSession {
      _ = try await runner.run(arguments: ["select-layout", "-t", "=\(session):", "tiled"])
    }
    return PaneID(rawValue: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// `/bin/sleep` への symlink を Agent 名で置く場所と、`codex` の PID を親 shell に書かせるファイル。
private struct AgentWorkspace {
  struct Panes {
    let claude: PaneID
    let claudePID: Int32
    let codex: PaneID
    let codexPID: Int32
  }

  private let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "awt-pane-summary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["claude", "codex"] {
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: name),
        withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func source(_ contents: String, runner: TmuxRunner) async throws {
    let file = directory.appending(path: "source-\(UUID().uuidString).conf")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    _ = try await runner.run(arguments: ["source-file", file.path])
  }

  func startAgents(in worktree: WorktreeIdentity, runner: TmuxRunner) async throws -> Panes {
    let session = TmuxSessionName(identity: worktree).rawValue
    let claudePath = directory.appending(path: "claude").path
    let codexPath = directory.appending(path: "codex").path
    let pidFile = directory.appending(path: "codex.pid")
    // claude は pane のコマンドそのもの (深さ 0)。
    let claude = try await runner.run(arguments: [
      "new-session", "-d", "-s", session, "-x", "200", "-y", "50", "-P", "-F",
      "#{pane_id} #{pane_pid}", "\(claudePath) 600",
    ])
    // codex は shell の子 (深さ 1)。`&` で起こして shell を親に残す。codex の終了後も pane を
    // 残すため、`wait` の後は Agent 名でないプロセスに置き換える。
    let codex = try await runner.run(arguments: [
      "split-window", "-d", "-t", "=\(session):", "-P", "-F", "#{pane_id}",
      "/bin/sh -c '\(codexPath) 600 & echo $! > \(pidFile.path); wait; exec /bin/sleep 600'",
    ])
    let claudeFields = claude.stdout.split(separator: " ")
    try await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) }
    let codexPID = try #require(
      Int32(
        try String(contentsOf: pidFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    return Panes(
      claude: PaneID(rawValue: String(claudeFields[0])),
      claudePID: try #require(
        Int32(claudeFields[1].trimmingCharacters(in: .whitespacesAndNewlines))),
      codex: PaneID(rawValue: codex.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
      codexPID: codexPID)
  }
}

private func waitUntil(
  timeout: Duration = .seconds(10), _ condition: () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(100))
  }
  Issue.record("条件が \(timeout) 以内に成り立たなかった")
}
