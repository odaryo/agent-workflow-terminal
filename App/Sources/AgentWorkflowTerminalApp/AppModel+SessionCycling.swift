import TerminalCore

extension AppModel {
  var sessionCycleOrder: [TerminalSessionKey] {
    let selectableWorktrees = sessionWorktrees.filter {
      $0.activation == .active && $0.detected.isReachable
    }
    return sessionKeys.filter { key in
      key.identity == projectRoot?.identity
        || selectableWorktrees.contains { $0.identity == key.identity }
    }
  }
}

extension ProjectsModel {
  func selectAdjacentSession(forward: Bool) {
    let sessions = availableModels.flatMap { model in
      model.sessionCycleOrder.map { (model: model, key: $0) }
    }
    guard
      let next = SessionCycle.adjacent(
        in: sessions.map(\.key), from: selectedModel?.displayedSession, forward: forward),
      let destination = sessions.first(where: { $0.key == next })
    else {
      return
    }
    if selectedModel !== destination.model {
      select(destination.model.project.commonDirectory)
    }
    destination.model.select(next)
    destination.model.paneObservations.requestTerminalFocus()
  }
}
