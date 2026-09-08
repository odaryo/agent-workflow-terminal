import Adapters
import Foundation
import TerminalCore
import Testing

private let isSendGateIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "§9.2.2 送信可否の判定 (実 tmux)",
  .enabled(if: isSendGateIntegrationEnabled)
)
struct DiffCommentSendGateIntegrationTests {

  /// Issue #240 の計測をそのまま回帰にする。前景で `sleep` が走っている pane へ貼ると、注入は
  /// 成功として返るが本文は tty のバッファに残り、`sleep` が終わってシェルが読んだ時点で
  /// **コマンドとして実行される**。gate 経由なら1バイトも送らないので実行もされない。
  @Test("Working 中の pane へは送らない (対照: 状態を見ない経路では本文が実行される)")
  func doesNotSendToWorkingPane() async throws {
    let socketName = uniqueSocketName("send-gate-working")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let workspace = try IntegrationWorkspace()
      defer { workspace.remove() }

      // 対照: 状態を見ない修正前の経路。
      let control = IntegrationExecutionProbe(workspace: workspace, name: "control")
      let controlPane = try await makeWorkingPane(runner, label: "control")
      try await TmuxTextInjection(runner: runner).inject(control.text, into: controlPane)

      // 修正後: 同じ pane 構成に対し `DiffCommentSendGate` を通す。
      let guarded = IntegrationExecutionProbe(workspace: workspace, name: "guarded")
      let guardedPane = try await makeWorkingPane(runner, label: "guarded")
      let sendability = DiffCommentSendGate.sendability(
        toPane: guardedPane, states: [Self.state(.working, pane: guardedPane)])
      if case .allowed = sendability {
        try await TmuxTextInjection(runner: runner).inject(guarded.text, into: guardedPane)
      }

      // 「まだ実行されていない」は、窓の中に居ることを確かめてからでないと意味を持たない。
      let insideWindow = try await isInsideSleepWindow(runner, pane: controlPane)
      #expect(insideWindow, "sleep が先に終わったため、この計測は条件を再現できていない")
      if insideWindow { #expect(!control.didExecute) }
      print(
        "[measure] 窓の中 (SLEEP_END 未出力)? \(insideWindow) "
          + "/ control marker exists? \(control.didExecute) "
          + "/ guarded sendability=\(sendability)")
      try await waitUntil("対照の pane で sleep が終わり、本文が実行される") { control.didExecute }
      print(
        "[measure] sleep 終了後: control marker exists? \(control.didExecute) "
          + "/ guarded marker exists? \(guarded.didExecute)")
      #expect(sendability == .blocked(.paneState(.working)))
      #expect(control.didExecute)
      #expect(!guarded.didExecute)
    }
  }

  /// 決定 (2026-09-08) の許可集合をそのまま実 pane で確かめる。`completed` を不可にすると
  /// §9.2 の主フローが塞がるので、可側の陽性も見る。
  @Test("許可集合どおりに送る / 送らない", arguments: [AgentState.completed, .idle, .error, .unknown])
  func honoursTheDecidedAllowedSet(_ state: AgentState) async throws {
    let socketName = uniqueSocketName("send-gate-\(state.rawValue)")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let workspace = try IntegrationWorkspace()
      defer { workspace.remove() }
      let probe = IntegrationExecutionProbe(workspace: workspace, name: state.rawValue)
      let pane = try await makeShellPane(runner, label: state.rawValue)

      let sendability = DiffCommentSendGate.sendability(
        toPane: pane, states: [Self.state(state, pane: pane)])
      if case .allowed = sendability {
        try await TmuxTextInjection(runner: runner).inject(probe.text, into: pane)
      }

      try await Task.sleep(for: .seconds(1))
      let delivered = try await capturePane(runner, pane: pane).contains(probe.token)
      print("[measure] \(state.rawValue): \(sendability) / delivered=\(delivered)")
      #expect(delivered == (sendability == .allowed))
      #expect((sendability == .allowed) == [.idle, .completed].contains(state))
    }
  }

  /// Agent が居ない pane は `WorktreePaneAgentStateFeed` の出力に現れない (`.absent`)。
  @Test("状態エントリが無い pane へは送らない")
  func doesNotSendWhenTheDestinationHasNoObservedState() async throws {
    let socketName = uniqueSocketName("send-gate-unobserved")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let workspace = try IntegrationWorkspace()
      defer { workspace.remove() }
      let probe = IntegrationExecutionProbe(workspace: workspace, name: "unobserved")
      let pane = try await makeShellPane(runner, label: "unobserved")

      let sendability = DiffCommentSendGate.sendability(toPane: pane, states: [])
      if case .allowed = sendability {
        try await TmuxTextInjection(runner: runner).inject(probe.text, into: pane)
      }

      try await Task.sleep(for: .seconds(1))
      let delivered = try await capturePane(runner, pane: pane).contains(probe.token)
      print("[measure] unobserved: \(sendability) / delivered=\(delivered)")
      #expect(sendability == .blocked(.stateUnobserved))
      #expect(!delivered)
    }
  }

  private static func state(_ state: AgentState, pane: PaneID) -> PaneAgentState {
    PaneAgentState(id: pane, state: state, lastUpdatedAt: Date())
  }

  /// 前景で `sleep` を走らせ、終わったらシェルが tty を読む pane。Issue #240 の計測と同じ形。
  ///
  /// `/bin/sh` を明示するのは、tmux が command 文字列を**既定 shell 経由**で走らせるため
  /// (実測: 文字列だけ渡すと `#{pane_current_command}` は `zsh` / `bash` になる)。
  /// `pane_current_command` は待ち合わせの目印に使えないので、pane 自身に窓の開始と終了を
  /// 画面へ書かせ、それで同期する。時間で待つと負荷の高いマシンで判定が反転する。
  private func makeWorkingPane(_ runner: TmuxRunner, label: String) async throws -> PaneID {
    let pane = try await makePane(
      runner, label: label,
      command: [#"/bin/sh -c "echo SLEEP_START; sleep 4; echo SLEEP_END; exec /bin/sh""#])
    try await waitUntil("前景の sleep が始まる") {
      try await capturePane(runner, pane: pane).contains("SLEEP_START")
    }
    return pane
  }

  /// 前景の `sleep` がまだ終わっていないこと。これを確かめずに「まだ実行されていない」と
  /// assert すると、窓が閉じた後の観測を「送られていない証拠」と読み違える。
  private func isInsideSleepWindow(_ runner: TmuxRunner, pane: PaneID) async throws -> Bool {
    try await !capturePane(runner, pane: pane).contains("SLEEP_END")
  }

  /// prompt を出して待っている pane。prompt が見えていれば zle が動いている。
  /// prompt を `-e "PS1=..."` で渡さない理由は `ShellPromptZDotDir` に書いた (Issue #290)。
  private func makeShellPane(_ runner: TmuxRunner, label: String) async throws -> PaneID {
    let prompt = try ShellPromptZDotDir()
    defer { prompt.remove() }
    let pane = try await makePane(runner, label: label, command: prompt.shellArguments)
    try await waitUntil("shell の prompt 表示") {
      try await capturePane(runner, pane: pane).contains(ShellPromptZDotDir.marker)
    }
    return pane
  }

  /// `command` は tmux の argv。要素が1つなら tmux は既定 shell 経由で解釈し、複数なら
  /// shell を挟まずそのまま exec する (実測)。
  private func makePane(
    _ runner: TmuxRunner, label: String, command: [String]
  ) async throws -> PaneID {
    let created = try await runner.run(
      arguments: [
        "new-session", "-d", "-s", "awt-send-gate-\(label)", "-x", "200", "-y", "50",
        "-P", "-F", "#{pane_id}",
      ] + command)
    return PaneID(rawValue: created.stdout.trimmingCharacters(in: .newlines))
  }

  private func capturePane(_ runner: TmuxRunner, pane: PaneID) async throws -> String {
    try await runner.run(arguments: ["capture-pane", "-p", "-t", pane.rawValue]).stdout
  }

  private func display(_ runner: TmuxRunner, pane: PaneID, format: String) async throws -> String {
    try await runner.run(arguments: ["display-message", "-p", "-t", pane.rawValue, format])
      .stdout.trimmingCharacters(in: .newlines)
  }

  private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(20),
    condition: () async throws -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw IntegrationTimeout(description: description)
  }
}

private struct IntegrationTimeout: Error, CustomStringConvertible {
  let description: String
}
