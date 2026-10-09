import Foundation
import TerminalCore

extension AppModel {
  /// Task Tab の Close (設計書 §3.4)。Project Root は Close の対象ではないので受け付けない。
  func requestClose(of identity: WorktreeIdentity) {
    guard
      let worktree = worktrees.first(where: { $0.identity == identity }),
      worktree.activation == .active, worktree.detected.isReachable
    else { return }
    closing.open(
      target: worktree.detected,
      context: WorktreeCloseContext(
        repositoryDirectory: URL(fileURLWithPath: projectRoot?.worktreePath ?? project.directory),
        projectRootBranch: projectRoot?.branch,
        currentTarget: { [weak self] in
          self?.worktrees.first { $0.identity == identity }?.detected
        },
        didClose: { [weak self] in self?.finishClose(of: $0) }))
  }

  /// §3.4 の4択はどれも Inactive 化を伴う。選択肢3・4で消えた worktree は、次のスキャンで
  /// 消失として一覧から落ちる (§3.2)。
  private func finishClose(of identity: WorktreeIdentity) {
    // 先に隣を選ぶ。`setActivation` の中の `close` は選択中のタブを外すと Project Root へ移し、
    // その端末 (tmux client) を開いてしまう。
    if selectedIdentity == identity, let neighbor = neighborTab(of: identity) {
      select(neighbor)
    }
    setActivation(.inactive, of: identity)
  }

  /// 右隣、無ければ左隣の選べるタブ。どちらも無ければ `nil` で、`setActivation` が Project Root を選ぶ。
  private func neighborTab(of identity: WorktreeIdentity) -> TaskWorktree? {
    let tabs = tabbedWorktrees
    guard let index = tabs.firstIndex(where: { $0.identity == identity }) else { return nil }
    return tabs[tabs.index(after: index)...].first { $0.detected.isReachable }
      ?? tabs[..<index].last { $0.detected.isReachable }
  }
}
