import TerminalCore

extension AppModel {
  /// Task Tab と Overview と通知で同じ見出しを出す。
  func worktreeTitle(of identity: WorktreeIdentity) -> String {
    if projectRoot?.identity == identity { return "Project Root" }
    return worktrees.first { $0.identity == identity }?.detected.tabName ?? identity.rawValue
  }

  /// 登録が今もその pane を指すときだけ返す — `%N` だけで照合すると、server の再起動で振り直された
  /// 別の pane に印が付く (`PaneObservationStore.Observed.processIDs`)。
  func mainPane(of identity: WorktreeIdentity) -> PaneID? {
    guard let registration = mainPanes.registry.registration(for: identity),
      paneObservations.observed[identity]?.processIDs[registration.pane]
        == registration.processID
    else { return nil }
    return registration.pane
  }
}
