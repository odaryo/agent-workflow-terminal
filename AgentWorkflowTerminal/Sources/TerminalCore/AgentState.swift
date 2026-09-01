/// case の集合は設計書 `docs/architecture.md` §12「Agent Adapterと状態モデル」の写し。
/// Agent 固有の状態語彙をここへ足さない (§12.1)。
///
/// - Important: `unknown` は「状態を確定できなかった」ことを表す一級の状態であり、
///   推測で `working` / `idle` へ丸めてはならない (§12.3)。
public enum AgentState: String, Sendable, Hashable, CaseIterable, Codable {
  case working
  case question
  case permission
  case completed
  case error
  case idle
  /// `idle` との違いは、Agent プロセスの存在は確認できていること。
  /// プロセスごと居ない場合をここへ入れない。
  case unknown
}

/// 順序は設計書 §12.2 の `Needs Attention > Ready for Review > Working > Idle` が出典。
///
/// - Note: `unknown` の順位だけは設計書に明記が無い。§12.3 の「`Working` / `Idle` へ
///   丸めない」という制約だけを満たす位置として `working` と `idle` の間に置いている。
///   確定した順位ではないため、変更が必要になった場合は `priority` の1箇所を直せばよい。
public enum WorktreeStateCategory: String, Sendable, Hashable, Comparable, CaseIterable, Codable {
  case idle
  case unknown
  case working
  case readyForReview
  /// question / permission / error をまとめた分類。詳細は `AgentState` 側で保持する。
  case needsAttention

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.priority < rhs.priority
  }

  /// 順序を `rawValue` の辞書順にも case の宣言順にも依存させないため、明示的な数値で持つ。
  /// case を並べ替えても rawValue を変えても優先順位が壊れない。
  private var priority: Int {
    switch self {
    case .idle: 0
    case .unknown: 1
    case .working: 2
    case .readyForReview: 3
    case .needsAttention: 4
    }
  }
}

extension AgentState {
  public var worktreeCategory: WorktreeStateCategory {
    // 対応表の出典は設計書 §12.2。とくに completed を needsAttention に寄せないこと。
    switch self {
    case .question, .permission, .error: .needsAttention
    case .completed: .readyForReview
    case .working: .working
    case .idle: .idle
    // §12.3: 「確定できていない」と「何もしていない」は別物。ここを idle へ寄せると
    // 通知すべき状態を取りこぼすため、独立した分類のままにする。
    case .unknown: .unknown
    }
  }
}
