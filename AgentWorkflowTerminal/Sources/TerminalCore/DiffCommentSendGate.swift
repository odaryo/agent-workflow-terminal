/// 送信を止めた理由。3つを畳まない — ユーザーが取る次の行動が違う。
/// `paneState(.unknown)` は Agent は居るが状態を確定できない、`stateUnobserved` はその pane に
/// Agent が居ない (素のシェル pane 等)、`observationUnavailable` は**その worktree の観測経路が
/// そもそも無い** (到達不能な worktree など) で、最後のものは pane の問題ではない。
public enum DiffCommentSendBlock: Sendable, Equatable {
  case paneState(AgentState)
  case stateUnobserved
  case observationUnavailable
}

public enum DiffCommentSendability: Sendable, Equatable {
  case allowed
  case blocked(DiffCommentSendBlock)
}

/// Diff レビューコメントを実装 Agent pane へ送ってよいかの判定 (設計書 §9.2.2、Issue #240)。
///
/// - Important: **判定はここ1箇所に閉じる。** UI の無効化と実際の送信経路が別々に条件を書くと、
///   片方だけ直って抜け道が残る。呼び出し側は許可集合を持たず `sendability(toPane:states:)` の
///   結果だけを見る。
/// - Important: **判定してから貼るまでの窓は残る。** 状態は `WorktreePaneAgentStateFeed` の
///   ポーリング (P1 の暫定値で 2 秒間隔) が届けた最後の観測であって、いま現在の pane の状態では
///   ない。`completed` と判定した直後にユーザーが同じ pane でコマンドを走らせれば、貼った本文は
///   Working 中の pane に入る。
///
///   窓が残る理由は「tmux から何も観測できないから」ではない。tmux の format には
///   `pane_current_command` (pane の tty の前景プロセス) があり、`TmuxTextInjection` の gate と
///   同じ `if-shell -F` に載せれば「前景が変わっていたら貼らない」までは1コマンドで書ける
///   (実測: 素のシェルへ戻った pane で `zsh` / `sleep` と変化し、条件に使える)。それを条件に
///   していないのは設計判断で、`pane_current_command` は Agent 状態の **proxy** にすぎず、
///   長命な Agent プロセスの中の `Working` と `Completed` を区別できない (`claude` は
///   どちらでも `claude`)。可否の根拠を proxy へ移すと「状態は `AgentAdapter` が決める」
///   という §12.1 の境界が曖昧になるため、`AgentState` だけを根拠にしている。
///   この窓を本当に埋められるのは Agent 側の明示信号 (§12.7 のハーネス連携) である。
public enum DiffCommentSendGate {
  /// 送信を許可する状態 (ユーザー決定 2026-09-08、Issue #240)。
  ///
  /// `completed` を含めるのは、その pane が空の入力欄で次のプロンプトを待っており `idle` と
  /// 同じ安全性のため。実測上、Agent がターンを終えた後の pane は `idle` にならない
  /// (`ClaudeCodeAdapter` の `idle` は起動バナーが画面に残っている間だけ。Gate 3 §10-4) ので、
  /// これを外すと §9.2 の主フローで送信が常に無効になる。
  ///
  /// `error` は含めない。Agent が落ちて pane が素のシェルへ戻っていると、コメント本文が
  /// コマンドとして実行される (Issue #240 の危険そのもの)。
  public static let sendableStates: Set<AgentState> = [.idle, .completed]

  /// `states` は `WorktreePaneAgentStateFeed` が出した最後の観測をそのまま渡す。`nil` は
  /// 観測経路が無いこと (到達不能な worktree 等) を表し、空配列 (経路はあるが Agent pane が
  /// 1つも無い) と区別する。送信先が含まれていなければ `stateUnobserved` で、`idle` へは
  /// 丸めない (§12.3 と同じ作法)。
  public static func sendability(
    toPane pane: PaneID,
    states: [PaneAgentState]?
  ) -> DiffCommentSendability {
    guard let states else { return .blocked(.observationUnavailable) }
    guard let observed = states.first(where: { $0.id == pane }) else {
      return .blocked(.stateUnobserved)
    }
    guard sendableStates.contains(observed.state) else {
      return .blocked(.paneState(observed.state))
    }
    return .allowed
  }
}
