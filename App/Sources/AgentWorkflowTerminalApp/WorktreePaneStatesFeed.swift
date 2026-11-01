import Adapters
import Foundation
import TerminalCore

/// Project Root も対象にする。TaskWorktree に限定すると §9.2.2 の送信が恒久的に不可になる。
typealias WorktreePaneStatesFeed =
  @Sendable (TerminalSessionKey) -> AsyncStream<WorktreePaneAgentStates>

/// fallback adapter が Agent とみなすプロセス名。§12.7 の「現在の Agent プロセス」も同じ集合で
/// 判定する — 別の集合にすると、状態は Agent と出るのに連携変数が「現役でない」と捨てられる。
let agentProcessNames: Set<String> = ["claude", "codex"]

/// - Note: `signals` は Agent の画面変化を追う間隔、`liveness` は process の生存確認、
///   `paneListInterval` は pane 集合の再取得。いずれも P1 の暫定値で、根拠は
///   「体感で追随し、tmux への負荷が無視できる」程度でしかない。
///
/// `paneSource` は Overview の概要読み取り (`PaneObservationStore`) と同じものを渡す。pane 一覧と
/// 連携変数は1回の `list-panes` のキャッシュを共有しており、別の source を作るとキャッシュが分かれて
/// `list-panes` の起動が増える。
func makeWorktreePaneStatesFeed(
  paneSource: TmuxWorktreePaneSource,
  signalSource: any AgentSignalSource
) -> WorktreePaneStatesFeed {
  let feed = WorktreePaneAgentStateFeed(
    adapters: [ClaudeCodeAdapter(), CodexAdapter()],
    fallback: ProcessDetectionFallbackAdapter(processNames: agentProcessNames),
    intervals: AgentObservationIntervals(signals: .seconds(2), liveness: .seconds(5)),
    paneListInterval: .seconds(2)
  )
  return { key in
    feed.snapshots(of: key, panes: paneSource, signals: signalSource)
  }
}
