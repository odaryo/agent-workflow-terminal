public enum TerminalTabSessionRule {
  public enum AfterExit: Sendable, Equatable {
    case closeTab
    case offerReattach
  }

  public enum OnOpen: Sendable, Equatable {
    case attachOrCreate
    case closeTab
    case offerCreate
  }

  public static func afterExit(sessionExists: Bool?, tabsInDirectory: Int) -> AfterExit {
    // 確かめられない nil を「無い」に丸めると、閉じたタブの作業をユーザーが見失う。
    guard sessionExists == false, tabsInDirectory >= 2 else { return .offerReattach }
    return .closeTab
  }

  /// 設計書 §3.3「起動時の復元でsessionが消えていたタブ」に従う。
  /// 存在を確かめられない nil でも黙って作成せず、明示操作後の attachCommand に server の probe を委ねる。
  public static func onOpen(
    sessionExists: Bool?,
    tabsInDirectory: Int,
    isNewlyAdded: Bool,
    isRestored: Bool
  ) -> OnOpen {
    // 新しく足したタブは session がまだ無いのが正常なので、閉じずに作成へ進める。
    guard !isNewlyAdded else { return .attachOrCreate }
    if afterExit(sessionExists: sessionExists, tabsInDirectory: tabsInDirectory) == .closeTab {
      return .closeTab
    }
    if isRestored, sessionExists != true {
      return .offerCreate
    }
    return .attachOrCreate
  }
}
