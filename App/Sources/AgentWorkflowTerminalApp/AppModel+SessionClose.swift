import TerminalCore

extension AppModel {
  func canCloseSession(_ key: TerminalSessionKey) -> Bool {
    guard sessionActivityProbe != nil, sessions != nil,
      sessionKeys.contains(key), canOpenSession(in: key.identity)
    else { return false }
    return key.identity != projectRoot?.identity || sessionLayout.tabs(in: key.identity).count > 1
  }

  func requestCloseSession(_ key: TerminalSessionKey) {
    guard canCloseSession(key), !sessionClosing.isTerminating else { return }
    if let session = closing.session, case .executing = session.phase { return }
    if sessionLayout.tabs(in: key.identity).count == 1 {
      requestClose(of: key.identity)
      return
    }
    guard let sessionActivityProbe else { return }
    closing.dismiss()
    sessionClosing.inspect(key, probe: sessionActivityProbe) { [weak self] activity in
      guard let self, self.canCloseSession(key), self.sessionLayout.tabs(in: key.identity).count > 1
      else { return }
      // shell の builtin だけのループや read 待ちは子プロセスが無く、確認なしで閉じる (§3.1)。
      if activity == .shellOnly {
        self.terminateSession(key)
      } else {
        self.sessionClosing.showConfirmation(
          key, title: self.sessionDisplayTitle(key), activity: activity)
      }
    }
  }

  func confirmCloseSession() {
    guard let confirmation = sessionClosing.confirmation else { return }
    terminateSession(confirmation.key)
  }

  private func terminateSession(_ key: TerminalSessionKey) {
    guard !sessionClosing.isTerminating, canCloseSession(key),
      sessionLayout.tabs(in: key.identity).count > 1, let sessions
    else {
      sessionClosing.cancel()
      return
    }
    sessionClosing.beginTermination()
    Task {
      defer { sessionClosing.finishTermination() }
      do {
        try await sessions.terminate(key)
      } catch {
        reportSessionClosingFailure("セッション「\(sessionDisplayTitle(key))」を終了できません: \(error)")
        return
      }
      discardSession(key)
    }
  }

  func discardSession(_ key: TerminalSessionKey) {
    guard sessionKeys.contains(key) else { return }
    newlyAddedSessions.remove(key)
    restoredSessions.remove(key)
    if displayedSession == key {
      if let neighbor = neighborSession(of: key) {
        select(neighbor)
      } else {
        displayedSession = nil
      }
    }
    removeSession(key)
  }

  private func neighborSession(of key: TerminalSessionKey) -> TerminalSessionKey? {
    let sessions = sessionKeys
    guard let index = sessions.firstIndex(of: key) else { return nil }
    let canSelect: (TerminalSessionKey) -> Bool = { self.canOpenSession(in: $0.identity) }
    return sessions[sessions.index(after: index)...].first(where: canSelect)
      ?? sessions[..<index].last(where: canSelect)
  }

  func sessionDisplayTitle(_ key: TerminalSessionKey) -> String {
    let name =
      if key.identity == projectRoot?.identity {
        "Project Root"
      } else {
        worktrees.first { $0.identity == key.identity }?.detected.directoryName
          ?? key.identity.rawValue
      }
    return key.index > 1 ? "\(name) \(key.index)" : name
  }
}
