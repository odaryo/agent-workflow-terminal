import TerminalCore

enum ClosePanelVisibility {
  static func showsWorktreeClose(
    for target: WorktreeIdentity, selected: WorktreeIdentity?, sessionKeys: [TerminalSessionKey]
  ) -> Bool {
    // §3.4 対象を Inactive にしてから結果を出す Close では、対象へ表示を戻せない。
    target == selected || !sessionKeys.contains { $0.identity == target }
  }

  static func showsSessionClose(
    for target: TerminalSessionKey, displayed: TerminalSessionKey?
  ) -> Bool {
    target == displayed
  }
}
