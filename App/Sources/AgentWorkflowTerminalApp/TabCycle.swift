import TerminalCore

enum TabCycle {
  static func adjacent(
    in order: [WorktreeIdentity], from current: WorktreeIdentity?, forward: Bool
  ) -> WorktreeIdentity? {
    guard let current, let index = order.firstIndex(of: current) else {
      return forward ? order.first : order.last
    }
    if forward {
      return index + 1 < order.count ? order[index + 1] : order.first
    }
    return index > 0 ? order[index - 1] : order.last
  }
}
