/// Agent の状態を Terminal 共通の語彙へ正規化したもの。
///
/// 設計書 `docs/architecture.md` §12「Agent Adapterと状態モデル」の写し。
/// 各 `AgentAdapter` は Agent 固有の情報をこの enum のいずれかへ正規化する。
///
/// - Important: `unknown` は「状態を確定できなかった」ことを表す一級の状態であり、
///   推測で `working` / `idle` へ丸めてはならない (§12.3)。
public enum AgentState: String, Sendable, Hashable, CaseIterable, Codable {
  /// Agent が処理中。
  case working
  /// Agent がユーザーへ質問しており、応答待ち。
  case question
  /// Agent が権限の承認を待っている。
  case permission
  /// Agent が作業を完了した (UI 上は Ready for Review として扱う)。
  case completed
  /// Agent がエラーで停止した。
  case error
  /// Agent が動作しておらず、待機している。
  case idle
  /// Agent プロセスの存在は確認できるが、Adapter が状態を確定できない。
  case unknown
}

/// worktree タブへ表示する代表状態の大分類。
///
/// 設計書 §12.2 の優先順位 `Needs Attention > Ready for Review > Working > Idle` を
/// `Comparable` の順序として表現する (case の宣言順が昇順)。
///
/// - Note: `unknown` の順位は設計書に明記が無い。§12.3 の「`Working` / `Idle` へ丸めない」
///   という制約だけを満たす位置として `working` と `idle` の間に置いている。
///   確定した順位ではないため、変更が必要になった場合はこの1箇所を直せばよい。
public enum WorktreeStateCategory: String, Sendable, Hashable, Comparable, CaseIterable, Codable {
  /// 何も待っておらず、注意も不要。
  case idle
  /// 状態を確定できていない。
  case unknown
  /// Agent が処理中。
  case working
  /// Agent が完了し、レビュー待ち。
  case readyForReview
  /// ユーザーの介入が必要 (question / permission / error)。
  case needsAttention

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.priority < rhs.priority
  }

  /// 数値が大きいほど優先度が高い。
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
  /// この状態が属する worktree 代表状態の大分類 (§12.2)。
  public var worktreeCategory: WorktreeStateCategory {
    switch self {
    // §12.2: Question / Permission / Error は Needs Attention として同列に扱う。
    case .question, .permission, .error: .needsAttention
    // §12.2: Agent 完了は Needs Attention ではなく Ready for Review。
    case .completed: .readyForReview
    case .working: .working
    case .idle: .idle
    // §12.3: Unknown は丸めず、独立した分類のままにする。
    case .unknown: .unknown
    }
  }
}
