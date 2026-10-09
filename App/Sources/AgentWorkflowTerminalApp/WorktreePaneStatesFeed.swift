import Adapters
import Foundation
import TerminalCore

/// worktree 1件を、その pane の Agent 状態列へ写す。#153 の `WorktreePaneAgentStateFeed` を
/// 起動時に1箇所で束ねるための境界であり、タブ側はこの型越しにしか観測経路を触らない。
///
/// - Important: 入力は `DetectedWorktree` であって `TaskWorktree` ではない。**Project Root の
///   pane も観測する**ため (§9.2.2 の送信可否がこの観測に依存しており、`TaskWorktree` を
///   要求すると Project Root タブで送信が恒久的に不可になる)。§2.3 が禁じているのは Project
///   Root に Active/Inactive を持たせることで、pane を観測することではない。`TaskWorktree` の
///   precondition はそのまま残す。
typealias WorktreePaneStatesFeed =
  @Sendable (DetectedWorktree) -> AsyncStream<WorktreePaneAgentStates>

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
  return { worktree in
    feed.snapshots(of: worktree.identity, panes: paneSource, signals: signalSource)
  }
}
