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
    let order = tabKeys.filter { key in
      key.identity == projectRoot?.identity
        || selectableWorktrees.contains { $0.identity == key.identity }
    }
    guard let next = TabCycle.adjacent(in: order, from: selectedTab, forward: forward) else {
      return
    }
    select(next)
  }
}
