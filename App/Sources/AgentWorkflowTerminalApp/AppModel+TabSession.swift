import TerminalCore

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

  func shouldOpenTab(_ key: TerminalSessionKey) async -> Bool {
    guard tabKeys.contains(key) else { return false }
    let sessionExists = try? await sessions?.exists(key)
    guard !Task.isCancelled, tabKeys.contains(key) else { return false }
    let action = TerminalTabSessionRule.onOpen(
      sessionExists: sessionExists,
      tabsInDirectory: tabLayout.tabs(in: key.identity).count,
      isNewlyAdded: newlyAddedTabs.contains(key))
    guard action == .closeTab else { return true }
    reportTabClosingFailure(
      "タブ「\(tabTitle(key))」の tmux session は外部で終了していたため、タブを閉じました。")
    discardTab(key)
    return false
  }

  func didPrepareTab(_ key: TerminalSessionKey) {
    newlyAddedTabs.remove(key)
  }
}
