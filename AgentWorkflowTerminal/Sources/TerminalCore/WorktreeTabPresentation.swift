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

  /// タブから選んで開ける Task worktree。到達不能なタブを選ばせないのは、
  /// `tmux new-session -c <存在しないディレクトリ>` が黙って `$HOME` へ落ちるためである
  /// (`AppModel.select(_:)` の doc コメント参照)。
  public var selectableTaskWorktrees: [TaskWorktree] {
    tabbedTaskWorktrees.filter(\.detected.isReachable)
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

  /// タブ列の代わりに案内を出すべき状態。`nil` は「案内を出さない」で、端末の領域をそのまま
  /// 出す (選択が無ければ空のまま)。
  ///
  /// - Important: `didCompleteInitialScan` が `false` の間は必ず `nil` を返す。初回スキャンの
  ///   前は Project Root も worktree も 0 件に見えるので、条件だけで判定すると**観測していない
  ///   状態を「無い」と断定する** (設計書 §12.3、Issue #243)。スキャンは worktree ごとの git
  ///   実行で、到達しにくい1件があれば窓は伸びる。
  /// - Important: 選べるタブが1つでもあれば案内を出さない。出すと、案内が端末の領域ごと
  ///   差し替わるため、Inactive を Active 化した直後のように**選択がまだ無いだけ**の状態で、
  ///   既に開いている他タブの端末まで階層から外れる。
  public func tabEmptyState(
    hasSelection: Bool,
    didCompleteInitialScan: Bool
  ) -> WorktreeTabEmptyState? {
    guard didCompleteInitialScan, !hasSelection else { return nil }
    guard projectRoot == nil, selectableTaskWorktrees.isEmpty else { return nil }
    // ここへ来る時点で Project Root は無い。在れば選べるタブとして上で除かれている。
    guard !taskWorktrees.isEmpty else { return .noWorktrees }
    // Active はあるのに選べるものが無い = すべて到達可能でない。「Active が無い」と出すと、
    // 実際には出ているタブの説明にならない。
    guard tabbedTaskWorktrees.isEmpty else { return .noReachableWorktrees }
    return .noActiveWorktrees
  }
}

/// 文言は持たない。表示層の語彙 (「Inactive の一覧」など UI の名前) をドメインへ持ち込まない
/// ため (docs/coding-guidelines.md §2.1)。
public enum WorktreeTabEmptyState: Sendable, Hashable {
  case noWorktrees
  /// Active なタブは在るが、どれも到達可能でない。
  case noReachableWorktrees
  /// worktree は在るが、すべて Inactive。
  case noActiveWorktrees
}
