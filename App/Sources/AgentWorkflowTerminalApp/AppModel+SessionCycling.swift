import TerminalCore

extension AppModel {
  var sessionCycleOrder: [TerminalSessionKey] {
    sessionKeys.filter { canOpenSession(in: $0.identity) }
  }

  func reconcileSessionSelection() {
    let sessions = Set(sessionKeys)
    openedSessions.formIntersection(sessions)
    guard let displayedSession else {
      selectFallbackSession()
      return
    }
    let isSelectable =
      if displayedSession.identity == projectRoot?.identity {
        projectRoot?.isReachable == true
      } else {
        inventory.selectableTaskWorktrees.contains { $0.identity == displayedSession.identity }
      }
    guard !sessions.contains(displayedSession) || !isSelectable else { return }
    selectFallbackSession()
  }

  func selectFallbackSession() {
    // 到達を確認できない Project Root の選択は何も変更しないため、先に判定しないと
    // 到達可能な Task へのフォールバックまで進まない。
    if projectRoot?.isReachable == true {
      selectProjectRoot()
    } else if let next = inventory.selectableTaskWorktrees.first {
      select(next)
    } else {
      displayedSession = nil
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
