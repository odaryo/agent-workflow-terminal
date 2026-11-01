public enum TerminalTabSessionRule {
  public enum AfterExit: Sendable, Equatable {
    case closeTab
    case offerReattach
  }

  public enum OnOpen: Sendable, Equatable {
    case attachOrCreate
    case closeTab
  }

  public static func afterExit(sessionExists: Bool?, tabsInDirectory: Int) -> AfterExit {
    // 確かめられない nil を「無い」に丸めると、閉じたタブの作業をユーザーが見失う。
    guard sessionExists == false, tabsInDirectory >= 2 else { return .offerReattach }
    return .closeTab
  }

  public static func onOpen(
    sessionExists: Bool?,
    tabsInDirectory: Int,
    isNewlyAdded: Bool
  ) -> OnOpen {
    // 新しく足したタブは session がまだ無いのが正常なので、閉じずに作成へ進める。
    guard !isNewlyAdded else { return .attachOrCreate }
    return afterExit(sessionExists: sessionExists, tabsInDirectory: tabsInDirectory) == .closeTab
      ? .closeTab : .attachOrCreate
  }
}
