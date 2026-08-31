import Foundation

/// tmux の pane 識別子 (`%0` 形式)。
///
/// 値の生成元は tmux CLI の `#{pane_id}` (Spikes/gate1/README.md §8.10)。
public struct PaneID: Sendable, Hashable, Codable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// pane 単位で観測した Agent 状態のスナップショット。
public struct PaneAgentState: Sendable, Hashable, Identifiable, Codable {
  public let id: PaneID
  /// 正規化済みの Agent 状態。
  public let state: AgentState
  /// この状態を最後に更新した時刻。§12.2 の「最終更新順」の判定に使う。
  public let lastUpdatedAt: Date

  public init(id: PaneID, state: AgentState, lastUpdatedAt: Date) {
    self.id = id
    self.state = state
    self.lastUpdatedAt = lastUpdatedAt
  }
}

/// worktree タブへ1つだけ表示する代表状態。
public struct WorktreeRepresentativeState: Sendable, Hashable, Codable {
  /// タブの優先順位を決める大分類。
  public let category: WorktreeStateCategory
  /// 代表となった pane の詳細状態 (アイコン等での区別に使う)。
  public let state: AgentState
  /// 代表となった pane。
  public let paneID: PaneID

  public init(category: WorktreeStateCategory, state: AgentState, paneID: PaneID) {
    self.category = category
    self.state = state
    self.paneID = paneID
  }
}

/// worktree 内の pane 状態から、タブへ表示する代表状態を1つ決める純粋関数。
///
/// 設計書 §12.2「pane状態とworktree代表状態」の規則:
///
/// 1. 大分類の優先順位は `Needs Attention > Ready for Review > Working > Idle`。
/// 2. `Question` / `Permission` / `Error` は `Needs Attention` として同列に扱い、
///    その中では最終更新順とする。
/// 3. Agent 完了は `Needs Attention` ではなく `Ready for Review` に分類する。
///
/// 加えて §12.3 に従い、`Unknown` は `Working` / `Idle` へ丸めない。
///
/// - Note: 同列内の並びは §12.2 が `Needs Attention` についてのみ言及しているが、
///   実装では全分類に対して一様に「最終更新が新しい pane を優先」を適用する。
///   分類・時刻ともに同じ場合は入力順の先頭を採り、結果を決定的にする。
/// - Parameter panes: worktree に属する pane の状態。順序は問わない。
/// - Returns: 代表状態。pane が1つも無ければ `nil`。
public func resolveWorktreeRepresentativeState(
  panes: [PaneAgentState]
) -> WorktreeRepresentativeState? {
  var best: PaneAgentState?

  for pane in panes {
    guard let current = best else {
      best = pane
      continue
    }

    let candidateCategory = pane.state.worktreeCategory
    let currentCategory = current.state.worktreeCategory

    if candidateCategory > currentCategory {
      best = pane
    } else if candidateCategory == currentCategory,
      pane.lastUpdatedAt > current.lastUpdatedAt
    {
      best = pane
    }
  }

  guard let representative = best else { return nil }

  return WorktreeRepresentativeState(
    category: representative.state.worktreeCategory,
    state: representative.state,
    paneID: representative.id
  )
}
