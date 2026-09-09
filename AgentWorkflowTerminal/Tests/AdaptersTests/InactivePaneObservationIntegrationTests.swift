import Adapters
import Foundation
import TerminalCore
import Testing

private let isInactiveObservationIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

/// Inactive worktree に対して tmux が1回も起動しないことを、**実プロセスの argv** で示す
/// (Issue #237)。判定を通した後の呼び出し回数を数えるのではなく、tmux 実行ファイルの位置に
/// 置いたシムが受け取った argv を数える — 判定と実行の間に別の観測経路が挟まっていれば、
/// モックでは見えずここでだけ見える。
///
/// - Important: **判別は pane ID で行う。session 名では行えない。** #239 で pane 一覧は
///   `list-panes -a` を全 worktree で共有する1回の起動になった (`TmuxAllSessionPaneListCache`)
///   ため、argv に session 名がまったく現れない。session 名で数える主張はこの時点で**恒真**に
///   なるので使わない。代わりに、pane を名指しする唯一の観測である `capture-pane` の argv に
///   Inactive の pane ID が現れないことを主張する。
/// - Important: そのため pane では **adapter が認識する名前のプロセス**を起こす。`sleep` の
///   ままだと liveness が `.absent` になり `signals` が呼ばれず、`capture-pane` が Active に
///   ついても 0 件になって、主張も陽性対照もまとめて恒真になる (実測: シムのログは
///   `list-panes -a` 3 行だけだった)。名前は `/bin/sleep` への **symlink** で作る — macOS で
///   署名済みシステムバイナリの**複製**は起動時に SIGKILL される (実測 exit 137) が、symlink は
///   署名が実体に対して検証されるため生き、`ps -o comm=` は symlink 側のパスを返す (実測)。
/// - Important: モデル層の gate だけを覆う。SwiftUI の view 側 (Inactive は描画されないので
///   `.task` が走らない) は構造的な保証で、ここでは測っていない。
@Suite(
  "Inactive worktree の pane 観測抑止",
  .enabled(if: isInactiveObservationIntegrationEnabled)
)
struct InactivePaneObservationIntegrationTests {
  /// `paneListInterval` の2倍より長く回す。1周期しか回さないと「まだ来ていない」と
  /// 「呼ばれない」を区別できない。
  private static let observationDuration = Duration.seconds(5)

  @Test("capture-pane の対象になるのは Active worktree の pane だけ")
  func neverInvokesTmuxForInactiveWorktrees() async throws {
    let realTmux = try #require(IsolatedTmuxServer.executableURL())
    let socketName = uniqueSocketName("inactive-feed")

    let active = try taskWorktree("active", activation: .active)
    let inactive = [
      try taskWorktree("inactive-1", activation: .inactive),
      try taskWorktree("inactive-2", activation: .inactive),
    ]
    let inventory = WorktreeInventory(
      projectRoot: nil, taskWorktrees: [active] + inactive)

    let agent = try AgentNamedExecutable(name: "claude")
    defer { agent.remove() }

    let observation = try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      // Inactive 側にも session を作る。作らないと「観測しても空だった」と「観測しなかった」を
      // 取り違え得る — 実在する session を観測しないことが主張である。
      // pane で走らせるのは adapter が名前で認識するプロセス。ここが `sleep` だと liveness が
      // `.absent` になり、`capture-pane` が Active についても 0 件になって主張ごと恒真になる。
      let panesBySession = try await Self.createSessions(
        for: inventory, agent: agent, runner: runner)

      let shim = try TmuxArgumentLog(realTmux: realTmux)
      // body が途中で throw しても一時ディレクトリを残さない。
      defer { shim.remove() }
      let shimRunner = try TmuxRunner(
        socketName: socketName,
        processRunner: FoundationProcessRunner(),
        executableCandidates: [shim.executableURL]
      )
      // アプリと同じ gate を通す。テストが独自の条件で絞ると、測っているのは実装ではなく
      // テストの条件になる。
      let observed = inventory.taskWorktrees.filter {
        inventory.observesPaneStates(of: $0.identity)
      }
      await Self.observe(observed, runner: shimRunner)
      #expect(observed.map(\.identity) == [active.identity])
      return (log: try shim.lines(), panesBySession: panesBySession)
    }

    let log = observation.log
    FileHandle.standardError.write(Data(("=== tmux argv log (\(log.count) 行)\n").utf8))
    FileHandle.standardError.write(Data((log.joined(separator: "\n") + "\n").utf8))

    let captures = log.filter { $0.contains("capture-pane") }
    func paneIDs(of worktree: TaskWorktree) throws -> [String] {
      let session = TmuxSessionName(identity: worktree.identity).rawValue
      return try #require(observation.panesBySession[session])
    }

    // Inactive の pane は一度も名指しされない。pane を名指しする観測は `capture-pane` だけで、
    // pane 一覧は `-a` の共有読み取りなので worktree を名指ししない。
    for worktree in inactive {
      for paneID in try paneIDs(of: worktree) {
        #expect(captures.filter { $0.contains(paneID) } == [])
      }
    }
    // 陽性対照。Active の pane が実際に `capture-pane` の argv に現れることまで確かめないと、
    // 「誰も観測していないので Inactive も観測されていない」という恒真な緑と区別できない。
    // **周期あたりの回数は主張しない** — 閾値を上げると並列負荷で落ちる時間依存の主張になる
    // (#319 と同型)。
    let activePaneIDs = try paneIDs(of: active)
    #expect(activePaneIDs.count == 1)
    for paneID in activePaneIDs {
      #expect(captures.filter { $0.contains(paneID) }.count >= 1)
    }
  }

  /// Inactive 側にも session を作る。作らないと「観測しても空だった」と「観測しなかった」を
  /// 取り違え得る — 実在する session を観測しないことが主張である。
  /// 戻り値は session 名から pane ID への対応で、**実 tmux から**読む (シムのログを汚さない)。
  private static func createSessions(
    for inventory: WorktreeInventory, agent: AgentNamedExecutable, runner: TmuxRunner
  ) async throws -> [String: [String]] {
    for worktree in inventory.taskWorktrees {
      let session = TmuxSessionName(identity: worktree.identity)
      _ = try await runner.run(
        arguments: ["new-session", "-d", "-s", session.rawValue, "\(agent.path) 600"])
    }
    let membership = try await runner.run(
      arguments: ["list-panes", "-a", "-F", "#{session_name} #{pane_id}"])
    var panesBySession: [String: [String]] = [:]
    for line in membership.stdout.split(separator: "\n") {
      let fields = line.split(separator: " ")
      guard fields.count == 2 else { continue }
      panesBySession[String(fields[0]), default: []].append(String(fields[1]))
    }
    return panesBySession
  }

  /// アプリと同じ配線で観測を回し、`observationDuration` の後に止める。
  private static func observe(
    _ worktrees: [TaskWorktree], runner: TmuxRunner
  ) async {
    let feed = WorktreePaneAgentStateFeed(
      adapters: [ClaudeCodeAdapter(), CodexAdapter()],
      fallback: ProcessDetectionFallbackAdapter(processNames: ["claude", "codex"]),
      intervals: AgentObservationIntervals(signals: .seconds(2), liveness: .seconds(5)),
      paneListInterval: .seconds(2)
    )
    let paneSource = TmuxWorktreePaneSource(runner: runner)
    let signals = TmuxAgentSignalSource(
      tmuxRunner: runner, processRunner: FoundationProcessRunner())
    let subscriptions = worktrees.map { worktree in
      Task {
        for await _ in feed.states(of: worktree.identity, panes: paneSource, signals: signals) {}
      }
    }
    try? await Task.sleep(for: observationDuration)
    for subscription in subscriptions {
      subscription.cancel()
    }
  }
}

/// 実 tmux を `exec` する前に argv を追記する `/bin/sh` のシム。実 tmux とログのパスは生成時に
/// スクリプトへ埋め込む — 環境変数に置くと、`TmuxRunner` が子へ渡す環境を絞っているため届かない。
private struct TmuxArgumentLog {
  let executableURL: URL
  private let logURL: URL
  private let directory: URL

  init(realTmux: URL) throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "awt-tmux-shim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    executableURL = directory.appending(path: "tmux")
    logURL = directory.appending(path: "argv.log")

    let script = """
      #!/bin/sh
      printf '%s\\n' "$*" >> '\(logURL.path)'
      exec '\(realTmux.path)' "$@"

      """
    try script.write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func lines() throws -> [String] {
    guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
    return contents.split(separator: "\n").map(String.init)
  }
}

private func taskWorktree(
  _ name: String,
  activation: WorktreeActivation
) throws -> TaskWorktree {
  let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/\(name)"))
  return TaskWorktree(
    detected: DetectedWorktree(
      identity: identity,
      worktreePath: "/repo/\(name)",
      branch: name,
      isProjectRoot: false
    ),
    activation: activation
  )
}

/// adapter が `processNames` で認識する名前を持つ、実際に起動できる実行ファイル。
///
/// `/bin/sleep` への **symlink** で作る。macOS では署名済みシステムバイナリを**複製**すると
/// 起動時に SIGKILL される (実測: `cp /bin/sleep …/claude` を実行して exit 137) 一方、symlink は
/// 署名が実体に対して検証されるため起動でき、`ps -o comm=` は symlink 側のパスを返す (実測)。
/// `ProcessTableSnapshot` は `comm` の最後のパス要素を名前に使うので、これで
/// `ClaudeCodeAdapter.processNames` に一致する。
private struct AgentNamedExecutable {
  let path: String
  private let directory: URL

  init(name: String) throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "awt-agent-name-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: name)
    try FileManager.default.createSymbolicLink(
      at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
    path = executable.path
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
