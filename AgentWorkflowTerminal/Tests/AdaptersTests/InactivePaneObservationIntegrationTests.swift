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
@Suite(
  "Inactive worktree の pane 観測抑止",
  .enabled(if: isInactiveObservationIntegrationEnabled)
)
struct InactivePaneObservationIntegrationTests {
  /// `paneListInterval` の2倍より長く回す。1周期しか回さないと「まだ来ていない」と
  /// 「呼ばれない」を区別できない。
  private static let observationDuration = Duration.seconds(5)

  @Test("Active の session だけが list-panes の対象になる")
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

    let log = try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      // Inactive 側にも session を作る。作らないと「観測しても空だった」と「観測しなかった」を
      // 取り違え得る — 実在する session を観測しないことが主張である。
      for worktree in inventory.taskWorktrees {
        let session = TmuxSessionName(identity: worktree.identity)
        _ = try await runner.run(arguments: ["new-session", "-d", "-s", session.rawValue])
      }

      let shim = try TmuxArgumentLog(realTmux: realTmux)
      let shimRunner = try TmuxRunner(
        socketName: socketName,
        processRunner: FoundationProcessRunner(),
        executableCandidates: [shim.executableURL]
      )
      let feed = WorktreePaneAgentStateFeed(
        adapters: [ClaudeCodeAdapter(), CodexAdapter()],
        fallback: ProcessDetectionFallbackAdapter(processNames: ["claude", "codex"]),
        intervals: AgentObservationIntervals(signals: .seconds(2), liveness: .seconds(5)),
        paneListInterval: .seconds(2)
      )
      let paneSource = TmuxWorktreePaneSource(runner: shimRunner)
      let signals = TmuxAgentSignalSource(
        tmuxRunner: shimRunner, processRunner: FoundationProcessRunner())

      // アプリと同じ gate を通す。テストが独自の条件で絞ると、測っているのは実装ではなく
      // テストの条件になる。
      let observed = inventory.taskWorktrees.filter {
        inventory.observesPaneStates(of: $0.identity)
      }
      let subscriptions = observed.map { worktree in
        Task {
          for await _ in feed.states(
            of: worktree.identity, panes: paneSource, signals: signals)
          {
          }
        }
      }
      try? await Task.sleep(for: Self.observationDuration)
      for subscription in subscriptions {
        subscription.cancel()
      }
      #expect(observed.map(\.identity) == [active.identity])
      let lines = try shim.lines()
      shim.remove()
      return lines
    }

    FileHandle.standardError.write(Data(("=== tmux argv log (\(log.count) 行)\n").utf8))
    FileHandle.standardError.write(Data((log.joined(separator: "\n") + "\n").utf8))

    for worktree in inactive {
      let session = TmuxSessionName(identity: worktree.identity).rawValue
      #expect(log.filter { $0.contains(session) } == [])
    }
    let activeSession = TmuxSessionName(identity: active.identity).rawValue
    let activeListPanes = log.filter { $0.contains("list-panes") && $0.contains(activeSession) }
    #expect(activeListPanes.count >= 2)
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
