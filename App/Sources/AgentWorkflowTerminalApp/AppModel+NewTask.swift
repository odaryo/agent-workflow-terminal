import TerminalCore

extension AppModel {
  func openNewTab(in identity: WorktreeIdentity) async {
    guard canOpenTab(in: identity), let sessions else { return }
    let names: [String]
    do {
      names = try await sessions.sessionNames()
    } catch {
      reportTabOpeningFailure("tmux session の一覧を取得できないため、新しいタブを開けません: \(error)")
      return
    }
    guard !Task.isCancelled, canOpenTab(in: identity) else { return }
    // 他クライアントが list から create までに同じ番号を作ると、Resume でその session を共有する。
    selectNewTab(in: identity, existingSessionNames: names)
  }
}
