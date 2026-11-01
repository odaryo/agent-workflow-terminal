import TerminalCore

extension AppModel {
  func sessionTitle(_ key: TerminalSessionKey) -> String {
    let title = worktreeTitle(of: key.identity)
    return key.index > 1 ? "\(title) \(key.index)" : title
  }

  func worktreeInput(_ key: TerminalSessionKey) -> OverviewWorktreeInput? {
    guard inventory.observesPaneStates(of: key.identity),
      let observed = paneObservations.observed[key]
    else { return nil }
    return OverviewWorktreeInput(
      session: key, paneStates: observed.displayStates, details: observed.details,
      mainPane: mainPane(of: key.identity))
  }
}
