import TerminalCore

extension AppModel {
  func selectNextTab() {
    selectAdjacentTab(forward: true)
  }

  func selectPreviousTab() {
    selectAdjacentTab(forward: false)
  }

  private func selectAdjacentTab(forward: Bool) {
    let selectableWorktrees = tabbedWorktrees.filter {
      $0.activation == .active && $0.detected.isReachable
    }
    let order = [projectRoot?.identity].compactMap { $0 } + selectableWorktrees.map(\.identity)
    guard let next = TabCycle.adjacent(in: order, from: selectedIdentity, forward: forward) else {
      return
    }
    if next == projectRoot?.identity {
      selectProjectRoot()
    } else if let worktree = selectableWorktrees.first(where: { $0.identity == next }) {
      select(worktree)
    }
  }
}
