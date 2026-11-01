import TerminalCore

extension AppModel {
  /// 到達不能な worktree を開かないのは、`tmux new-session -c <存在しないディレクトリ>` が
  /// エラーにならず `$HOME` へ黙って落ちるためである (tmux 3.4 実測: client の cwd が
  /// `/private/tmp` でも exit 0 で session ができ、`pane_current_path` は `$HOME` になる)。そこで agent を走らせると、
  /// worktree の名前を持つタブが実際には別のディレクトリで作業することになる。しかも
  /// 既存 session は Resume するため、その誤った session に以後ずっと再 attach され続ける。
  ///
  /// Inactive を開かないのは、タブが無い worktree の端末を作らないためである (設計書 §3.2)。
  /// Active 化そのものは open/attach を伴わず、session の用意はタブを選んだ時点に留める
  /// (§3.3: session が無いときに Terminal が黙って作らない)。
  func select(_ key: TerminalSessionKey) {
    if key.identity != projectRoot?.identity {
      guard let worktree = worktrees.first(where: { $0.identity == key.identity }),
        worktree.activation == .active, worktree.detected.isReachable
      else { return }
    }
    selectedTab = key
    openedTabs.insert(key)
  }

  func select(_ worktree: TaskWorktree) {
    guard let key = tabLayout.tabs(in: worktree.identity).first else { return }
    select(key)
  }

  func selectProjectRoot() {
    guard let projectRoot, let key = tabLayout.tabs(in: projectRoot.identity).first else { return }
    select(key)
  }

  var selectedWorktree: DetectedWorktree? {
    guard let selectedIdentity else { return nil }
    if let projectRoot, projectRoot.identity == selectedIdentity { return projectRoot }
    return worktrees.first { $0.identity == selectedIdentity }?.detected
  }
}
