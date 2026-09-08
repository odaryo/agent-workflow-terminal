import Foundation

/// メインpane (= 実装Agent pane) の候補 (設計書 §12.7 / §9.2)。
///
/// `isAgent` は選択の**材料**であって根拠ではない。Agent と判定された pane を自動で採用しない
/// (§12.7 確定: 候補が1つでも自動では選ばない)。
public struct MainPaneCandidate: Sendable, Equatable, Identifiable {
  public let pane: PaneSnapshot
  public let isAgent: Bool

  public var id: PaneID { pane.id }

  public init(pane: PaneSnapshot, isAgent: Bool) {
    self.pane = pane
    self.isAgent = isAgent
  }
}

/// - Important: `registeredPaneMissing` を `unregistered` へも `registered` へも丸めない。
///   登録を消して選び直させるか、そのまま待つかはユーザーの判断であり、別 pane への
///   自動的な付け替えは §12.7 が禁じている。
public enum MainPaneResolution: Sendable, Equatable {
  case unregistered(candidates: [MainPaneCandidate])
  case registered(PaneID, candidates: [MainPaneCandidate])
  case registeredPaneMissing(PaneID, candidates: [MainPaneCandidate])

  /// 選び直しの UI がどの状態からでも候補を出せるように、3つとも同じ候補を持つ。
  public var candidates: [MainPaneCandidate] {
    switch self {
    case .unregistered(let candidates), .registered(_, let candidates),
      .registeredPaneMissing(_, let candidates):
      candidates
    }
  }

  /// 登録が残っているのに pane が存在しない場合だけ非 `nil`。
  public var missingPane: PaneID? {
    guard case .registeredPaneMissing(let pane, _) = self else { return nil }
    return pane
  }
}

/// worktree ごとに 0 or 1 個のメインpaneを覚える (設計書 §12.7)。
/// 再起動を跨いだ永続化は Issue #208 の対象外で、この型はプロセス内のメモリだけを持つ。
public struct MainPaneRegistry: Sendable, Equatable {
  private var panes: [WorktreeIdentity: PaneID] = [:]

  public init() {}

  public func registeredPane(for worktree: WorktreeIdentity) -> PaneID? {
    panes[worktree]
  }

  public mutating func register(_ pane: PaneID, for worktree: WorktreeIdentity) {
    panes[worktree] = pane
  }

  public mutating func clear(for worktree: WorktreeIdentity) {
    panes[worktree] = nil
  }

  /// `panes` は tmux `list-panes` の順序をそのまま渡す。候補は生存 pane だけで、終了した pane
  /// (`PaneSnapshot.isDead`) は候補にも「登録先が存在する」根拠にもしない。
  public func resolve(
    for worktree: WorktreeIdentity,
    panes: [PaneSnapshot],
    agentPaneIDs: Set<PaneID> = []
  ) -> MainPaneResolution {
    let candidates = panes.filter { !$0.isDead }
      .map { MainPaneCandidate(pane: $0, isAgent: agentPaneIDs.contains($0.id)) }
    guard let registered = registeredPane(for: worktree) else {
      return .unregistered(candidates: candidates)
    }
    guard candidates.contains(where: { $0.id == registered }) else {
      return .registeredPaneMissing(registered, candidates: candidates)
    }
    return .registered(registered, candidates: candidates)
  }
}
