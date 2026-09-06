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

  private static func isSessionAbsent(_ stderr: String, session: TmuxSessionName) -> Bool {
    if stderr == "can't find window: \(session.rawValue)\n" { return true }
    if stderr.hasPrefix("no server running on ") { return true }
    return stderr.hasPrefix("error connecting to ")
      && stderr.hasSuffix(" (No such file or directory)\n")
  }
}
