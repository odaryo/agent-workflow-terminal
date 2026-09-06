import Adapters
import Foundation
import TerminalCore

/// worktree 1件を、その pane の Agent 状態列へ写す。#153 の `WorktreePaneAgentStateFeed` を
/// 起動時に1箇所で束ねるための境界であり、タブ側はこの型越しにしか観測経路を触らない。
typealias WorktreePaneStatesFeed = @Sendable (TaskWorktree) -> AsyncStream<[PaneAgentState]>

/// - Note: `signals` は Agent の画面変化を追う間隔、`liveness` は process の生存確認、
///   `paneListInterval` は pane 集合の再取得。いずれも P1 の暫定値で、根拠は
///   「体感で追随し、tmux への負荷が無視できる」程度でしかない。
func makeWorktreePaneStatesFeed(
  runner: TmuxRunner,
  signalSource: any AgentSignalSource
) -> WorktreePaneStatesFeed {
  let feed = WorktreePaneAgentStateFeed(
    adapters: [ClaudeCodeAdapter(), CodexAdapter()],
    fallback: ProcessDetectionFallbackAdapter(processNames: ["claude", "codex"]),
    intervals: AgentObservationIntervals(signals: .seconds(2), liveness: .seconds(5)),
    paneListInterval: .seconds(2)
  )
  let paneSource = TmuxWorktreePaneSource(runner: runner)

  return { worktree in
    feed.states(of: worktree.identity, panes: paneSource, signals: signalSource)
  }
}
