import Foundation

/// 値は tmux CLI の `#{pane_id}` をそのまま入れる (`%0` 形式、`%` 込み。
/// Spikes/gate1/README.md §8.10)。アプリ側で採番しない。
public struct PaneID: Sendable, Hashable, Codable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct PaneAgentState: Sendable, Hashable, Identifiable, Codable {
  public let id: PaneID
  public let state: AgentState
  public let unknownCategoryOverride: UnknownAgentCategoryOverride?
  public var category: WorktreeStateCategory {
    unknownCategoryOverride?.category ?? state.worktreeCategory
  }
  /// このフィールドが必要なのは、§12.2 が同順位の pane を「最終更新順」で並べるため。
  /// 観測した時刻ではなく、状態が変化した時刻を入れる。
  public let lastUpdatedAt: Date

  public init(
    id: PaneID,
    state: AgentState,
    lastUpdatedAt: Date
  ) {
    self.id = id
    self.state = state
    self.unknownCategoryOverride = nil
    self.lastUpdatedAt = lastUpdatedAt
  }

  public init(id: PaneID, observation: AgentStateObservation, lastUpdatedAt: Date) {
    self.id = id
    self.state = observation.state
    self.unknownCategoryOverride =
      observation.state == .unknown && observation.category == .needsAttention
      ? .needsAttention : nil
    self.lastUpdatedAt = lastUpdatedAt
  }
}

public enum UnknownAgentCategoryOverride: String, Sendable, Hashable, Codable {
  case needsAttention

  fileprivate var category: WorktreeStateCategory { .needsAttention }
}

public struct WorktreeRepresentativeState: Sendable, Hashable, Codable {
  public let category: WorktreeStateCategory
  /// `.unknown + .needsAttention` では `category` から導けない。別に持たせることで、
  /// 通知優先度を保ったまま詳細表示では未確定であることを示す。
  public let state: AgentState
  public let paneID: PaneID

  public init(category: WorktreeStateCategory, state: AgentState, paneID: PaneID) {
    self.category = category
    self.state = state
    self.paneID = paneID
  }
}

/// 規則の出典は設計書 §12.2「pane状態とworktree代表状態」および §12.3。
///
/// - Note: 同順位内の並びについて §12.2 は `Needs Attention` にしか言及していない。
///   実装では全分類へ一様に「最終更新が新しい pane を優先」を適用し、分類・時刻とも
///   同じ場合は入力順の先頭を採る。設計書に無い判断であり、UI のちらつきを避けるために
///   結果を決定的にすることだけを根拠にしている。
/// - Returns: pane が1つも無ければ `nil`。「pane が無い」と「Idle」は別物なので、
///   ここで `.idle` を捏造しない。
public func resolveWorktreeRepresentativeState(
  panes: [PaneAgentState]
) -> WorktreeRepresentativeState? {
  var best: PaneAgentState?

  for pane in panes {
    guard let current = best else {
      best = pane
      continue
    }

    let candidateCategory = pane.category
    let currentCategory = current.category

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
    category: representative.category,
    state: representative.state,
    paneID: representative.id
  )
}
