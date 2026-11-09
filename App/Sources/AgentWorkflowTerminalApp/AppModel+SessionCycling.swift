import TerminalCore

extension AppModel {
  func selectNextSession() {
    selectAdjacentSession(forward: true)
  }

  func selectPreviousSession() {
    selectAdjacentSession(forward: false)
  }

  private func selectAdjacentSession(forward: Bool) {
    let selectableWorktrees = sessionWorktrees.filter {
      $0.activation == .active && $0.detected.isReachable
    }
    let order = sessionKeys.filter { key in
      key.identity == projectRoot?.identity
        || selectableWorktrees.contains { $0.identity == key.identity }
    }
    guard let next = SessionCycle.adjacent(in: order, from: displayedSession, forward: forward)
    else {
      return
    }
    select(next)
  }
}
