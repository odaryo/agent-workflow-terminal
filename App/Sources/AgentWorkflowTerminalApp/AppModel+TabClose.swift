import TerminalCore

extension AppModel {
  func canCloseTab(_ key: TerminalSessionKey) -> Bool {
    guard sessionActivityProbe != nil, sessions != nil,
      tabKeys.contains(key), canOpenTab(in: key.identity)
    else { return false }
    return key.identity != projectRoot?.identity || tabLayout.tabs(in: key.identity).count > 1
  }

  func requestCloseTab(_ key: TerminalSessionKey) {
    guard canCloseTab(key), !tabClosing.isTerminating else { return }
    if let session = closing.session, case .executing = session.phase { return }
    if tabLayout.tabs(in: key.identity).count == 1 {
      requestClose(of: key.identity)
      return
    }
    guard let sessionActivityProbe else { return }
    closing.dismiss()
    tabClosing.inspect(key, probe: sessionActivityProbe) { [weak self] activity in
      guard let self, self.canCloseTab(key), self.tabLayout.tabs(in: key.identity).count > 1
      else { return }
      // shell の builtin だけのループや read 待ちは子プロセスが無く、確認なしで閉じる (§3.1)。
      if activity == .shellOnly {
        self.terminateTab(key)
      } else {
        self.tabClosing.showConfirmation(key, title: self.tabTitle(key), activity: activity)
      }
    }
  }

  func confirmCloseTab() {
    guard let confirmation = tabClosing.confirmation else { return }
    terminateTab(confirmation.key)
  }

  private func terminateTab(_ key: TerminalSessionKey) {
    guard !tabClosing.isTerminating, canCloseTab(key),
      tabLayout.tabs(in: key.identity).count > 1, let sessions
    else {
      tabClosing.cancel()
      return
    }
    tabClosing.beginTermination()
    Task {
      defer { tabClosing.finishTermination() }
      do {
        try await sessions.terminate(key)
      } catch {
        reportTabClosingFailure("タブ「\(tabTitle(key))」の session を終了できません: \(error)")
        return
      }
      if selectedTab == key {
        if let neighbor = neighborTab(of: key) {
          select(neighbor)
        } else {
          selectedTab = nil
        }
      }
      removeTab(key)
    }
  }

  private func neighborTab(of key: TerminalSessionKey) -> TerminalSessionKey? {
    let tabs = tabKeys
    guard let index = tabs.firstIndex(of: key) else { return nil }
    let canSelect: (TerminalSessionKey) -> Bool = { self.canOpenTab(in: $0.identity) }
    return tabs[tabs.index(after: index)...].first(where: canSelect)
      ?? tabs[..<index].last(where: canSelect)
  }

  private func tabTitle(_ key: TerminalSessionKey) -> String {
    let name =
      if key.identity == projectRoot?.identity {
        "Project Root"
      } else {
        worktrees.first { $0.identity == key.identity }?.detected.tabName ?? key.identity.rawValue
      }
    return key.index > 1 ? "\(name) \(key.index)" : name
  }
}
