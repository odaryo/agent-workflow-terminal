import Foundation
import TerminalCore

extension AppModel {
  /// Project Root は worktree の Close (設計書 §3.4) の対象ではないので受け付けない。
  func requestClose(of identity: WorktreeIdentity) {
    guard
      let worktree = worktrees.first(where: { $0.identity == identity }),
      worktree.activation == .active, worktree.detected.isReachable
    else { return }
    guard !sessionClosing.isTerminating else { return }
    sessionClosing.cancel()
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
    // 先に隣を選ぶ。`setActivation` の中の `close` は選択中のセッションを外すと Project Root へ移し、
    // その端末 (tmux client) を開いてしまう。
    if selectedIdentity == identity, let neighbor = neighborSession(of: identity) {
      select(neighbor)
    }
    setActivation(.inactive, of: identity)
    removeSessions(in: identity)
  }

  /// 右隣、無ければ左隣の選べるセッション。どちらも無ければ `nil` で、`setActivation` が Project Root を選ぶ。
  private func neighborSession(of identity: WorktreeIdentity) -> TerminalSessionKey? {
    let sessions = sessionKeys
    guard let first = sessions.firstIndex(where: { $0.identity == identity }),
      let last = sessions.lastIndex(where: { $0.identity == identity })
    else { return nil }
    let selectable = Set(inventory.selectableTaskWorktrees.map(\.identity))
    let canSelect: (TerminalSessionKey) -> Bool = {
      $0.identity == self.projectRoot?.identity || selectable.contains($0.identity)
    }
    return sessions[sessions.index(after: last)...].first(where: canSelect)
      ?? sessions[..<first].last(where: canSelect)
  }
}
