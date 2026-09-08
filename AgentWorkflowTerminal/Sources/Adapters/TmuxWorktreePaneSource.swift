import TerminalCore

public enum TmuxWorktreePaneSourceError: Error, Sendable, Equatable {
  case tmux(TmuxRunnerError)
}

public struct TmuxWorktreePaneSource: WorktreePaneSource, Sendable {
  private let runner: TmuxRunner

  public init(runner: TmuxRunner) {
    self.runner = runner
  }

  public func panes(
    of worktree: WorktreeIdentity
  ) async throws(TmuxWorktreePaneSourceError) -> [PaneSnapshot] {
    let session = TmuxSessionName(identity: worktree)
    do {
      // `-t <session>` だけでは tmux が target-window として current window へ解決するため、
      // session 配下の全 window を対象にする `-s` が必要になる (tmux 3.4 で実測)。
      let result = try await runner.run(
        arguments: [
          "list-panes", "-s", "-t", "=\(session.rawValue)", "-F", TmuxListPanes.format,
        ])
      return TmuxListPanes.parse(output: result.stdout).panes.map(\.snapshot)
    } catch {
      // tmux 3.4 は session 不在を3通りとも exit code 1 で返す (実測)。生 stderr は server
      // 稼働中が `can't find window: <name>\n`、未作成 socket が
      // `error connecting to <path> (No such file or directory)\n`、停止後に socket が残る場合が
      // `no server running on <path>\n`。前者は session target でも window 不在として報告するため、
      // session 名まで完全一致で判定する。
      if case .commandFailed(let exitCode, _, let stderr) = error,
        exitCode == 1,
        Self.isSessionAbsent(stderr, session: session)
      {
        return []
      }
      throw .tmux(error)
    }
  }

  /// tmux server の同一性 (`#{pid}`)。`nil` は server が居ない、または値を読めなかったことを
  /// 表し、呼び出し側はこれを「一致した」側へ倒さない (`MainPaneRegistry.resolve`)。
  ///
  /// `list-panes` の format ではなくこの単独コマンドで読むのは、`#{pid}` が pane ではなく
  /// server の属性で、全 pane・全 session に同じ値が並ぶだけだから (実測)。
  ///
  /// - Important: `panes(of:)` と2回に分かれるので、その間に server が入れ替わる窓がある。
  ///   **pane 一覧を読んだ後にこちらを読む**限り、窓に当たったときの組は「古い pane 一覧 +
  ///   新しい server PID」= 不一致になり、登録先が使えないと判断する側へ倒れる。逆向き
  ///   (新しい pane を古い server PID と組にする) はこの順序では起こらない。
  public func serverProcessID() async throws(TmuxWorktreePaneSourceError) -> Int32? {
    do {
      // target を付けない。tmux 3.4 は存在しない session を `-t` に渡しても exit 0 で server の
      // 値を返すため (実測)、target には意味が無く、あると絞り込めるように読めてしまう。
      let result = try await runner.run(arguments: ["display-message", "-p", "#{pid}"])
      return Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
      // server 不在は「同一性を確かめられなかった」であって障害ではない。判定は
      // `TmuxRunnerError.isServerAbsent` の1箇所に集めている (形が2つあるため)。
      if error.isServerAbsent { return nil }
      throw .tmux(error)
    }
  }

  private static func isSessionAbsent(_ stderr: String, session: TmuxSessionName) -> Bool {
    if stderr == "can't find window: \(session.rawValue)\n" { return true }
    // server ごと居ない場合も「この session の pane は無い」であって障害ではない。
    return TmuxRunnerError.isServerAbsent(stderr: stderr)
  }
}
