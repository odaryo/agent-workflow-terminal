/// タブ列に並べる worktree と、pane を観測してよい worktree の判定 (設計書 §3.2)。
///
/// - Important: 判定を表示層に置かない。タブ側とドロワー側がそれぞれ条件を書くと、片方だけが
///   Inactive を除外して「タブには出ないのに観測は走り続ける」状態になる (Issue #237 で実際に
///   起きた)。観測の可否を問う経路をこの1箇所に集める。
extension WorktreeInventory {
  /// 到達不能でも Active なら含める。設計書 §3.2 が「タブは一覧から消さずに残し」と定めており、
  /// 消すと復帰したときにユーザーの Active/Inactive 指定を辿れなくなる。
  public var tabbedTaskWorktrees: [TaskWorktree] {
    taskWorktrees.filter { $0.activation == .active }
  }

  public var inactiveTaskWorktrees: [TaskWorktree] {
    taskWorktrees.filter { $0.activation == .inactive }
  }

  /// pane の観測 (`list-panes` / `capture-pane` / liveness) を許す identity か。
  ///
  /// - Important: Project Root は Active/Inactive を持たない (§2.3) が、到達可能なら観測する。
  ///   除くと Project Root タブで送信可否 (§9.2.2) が恒久的に不可になる
  ///   (`WorktreePaneStatesFeed` の doc コメント参照)。
  /// - Important: `observationFailed` を観測してよい側へ倒さない。到達を確かめられていない
  ///   worktree への tmux 実行は `unreachable` と同じ理由で認めない (`DetectedWorktree` の doc
  ///   コメント参照)。
  public func observesPaneStates(of identity: WorktreeIdentity) -> Bool {
    if let projectRoot, projectRoot.identity == identity {
      return projectRoot.isReachable
    }
    guard let task = taskWorktrees.first(where: { $0.identity == identity }) else { return false }
    return task.activation == .active && task.detected.isReachable
  }
}
