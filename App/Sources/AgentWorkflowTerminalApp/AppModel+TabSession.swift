import TerminalCore

enum TerminalTabOpening: Equatable {
  case open
  case offerCreate
  case close
}

extension AppModel {
  func handleTabExit(_ key: TerminalSessionKey) async {
    guard tabKeys.contains(key) else { return }
    let sessionExists = try? await sessions?.exists(key)
    guard !Task.isCancelled, tabKeys.contains(key) else { return }
    if TerminalTabSessionRule.afterExit(
      sessionExists: sessionExists, tabsInDirectory: tabLayout.tabs(in: key.identity).count
    ) == .closeTab {
      discardTab(key)
    }
  }

  func shouldOpenTab(_ key: TerminalSessionKey) async -> TerminalTabOpening {
    guard tabKeys.contains(key) else { return .close }
    let sessionExists = try? await sessions?.exists(key)
    guard !Task.isCancelled, tabKeys.contains(key) else { return .close }
    let action = TerminalTabSessionRule.onOpen(
      sessionExists: sessionExists,
      tabsInDirectory: tabLayout.tabs(in: key.identity).count,
      isNewlyAdded: newlyAddedTabs.contains(key),
      isRestored: restoredTabs.contains(key))
    switch action {
    case .attachOrCreate:
      return .open
    case .offerCreate:
      return .offerCreate
    case .closeTab:
      reportTabClosingFailure(
        "タブ「\(tabTitle(key))」の tmux session は外部で終了していたため、タブを閉じました。")
      discardTab(key)
      return .close
    }
  }

  func approveSessionCreation(_ key: TerminalSessionKey) {
    restoredTabs.remove(key)
  }

  func didPrepareTab(_ key: TerminalSessionKey) {
    newlyAddedTabs.remove(key)
    restoredTabs.remove(key)
  }
}
