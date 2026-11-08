import TerminalCore

extension AppModel {
  func sessionTitle(_ key: TerminalSessionKey) -> String {
    let title = worktreeTitle(of: key.identity)
    return key.index > 1 ? "\(title) \(key.index)" : title
  }

  func worktreeInput(_ key: TerminalSessionKey) -> OverviewWorktreeInput? {
    guard inventory.observesPaneStates(of: key.identity) else { return nil }
    return OverviewWorktreeInput(
      session: key, observation: paneObservations.observed[key],
      mainPane: mainPane(of: key.identity))
  }
}

extension OverviewWorktreeInput {
  @MainActor
  init(
    session: TerminalSessionKey, observation: PaneObservationStore.Observed?, mainPane: PaneID?
  ) {
    self.init(
      session: session, paneStates: observation?.displayStates ?? [],
      details: observation?.details ?? [:], mainPane: mainPane,
      isObserved: observation?.paneStates != nil)
  }
}
