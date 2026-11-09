import TerminalCore

extension AppModel {
  func openNewSession(in identity: WorktreeIdentity) async {
    guard canOpenSession(in: identity), let sessions else { return }
    let names: [String]
    do {
      names = try await sessions.sessionNames()
    } catch {
      reportSessionWarning("tmux session の一覧を取得できないため、新しいセッションを開けません: \(error)")
      return
    }
    guard !Task.isCancelled, canOpenSession(in: identity) else { return }
    // 他クライアントが list から create までに同じ番号を作ると、Resume でその session を共有する。
    selectNewSession(in: identity, existingSessionNames: names)
  }
}
