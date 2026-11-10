import TerminalCore

enum TerminalTabOpening: Equatable {
  case open
  case offerCreate
  case close
}

extension AppModel {
  func handleSessionExit(_ key: TerminalSessionKey) async {
    guard sessionKeys.contains(key) else { return }
    let sessionExists = try? await sessions?.exists(key)
    guard !Task.isCancelled, sessionKeys.contains(key) else { return }
    if TerminalTabSessionRule.afterExit(
      sessionExists: sessionExists, tabsInDirectory: sessionLayout.tabs(in: key.identity).count
    ) == .closeTab {
      discardSession(key)
    }
  }

  func shouldOpenSession(_ key: TerminalSessionKey) async -> TerminalTabOpening {
    guard sessionKeys.contains(key) else { return .close }
    let sessionExists = try? await sessions?.exists(key)
    guard !Task.isCancelled, sessionKeys.contains(key) else { return .close }
    let action = TerminalTabSessionRule.onOpen(
      sessionExists: sessionExists,
      tabsInDirectory: sessionLayout.tabs(in: key.identity).count,
      isNewlyAdded: newlyAddedSessions.contains(key),
      isRestored: restoredSessions.contains(key))
    switch action {
    case .attachOrCreate:
      return .open
    case .offerCreate:
      return .offerCreate
    case .closeTab:
      reportSessionClosingFailure(
        "セッション「\(sessionDisplayTitle(key))」は外部で終了していたため、セッションを閉じました。")
      discardSession(key)
      return .close
    }
  }

  func approveSessionCreation(_ key: TerminalSessionKey) {
    restoredSessions.remove(key)
  }

  func consumeAgentCommand(for key: TerminalSessionKey) -> String? {
    pendingAgentCommands.removeValue(forKey: key)
  }

  func didPrepareSession(_ key: TerminalSessionKey) {
    pendingAgentCommands.removeValue(forKey: key)
    newlyAddedSessions.remove(key)
    restoredSessions.remove(key)
  }
}
