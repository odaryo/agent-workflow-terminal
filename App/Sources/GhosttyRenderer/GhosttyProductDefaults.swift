enum GhosttyProductDefaults {
  /// 単位は byte。libghostty のコンパイル既定に依存させない (設計書 §4.4)。
  static let scrollbackLimit: UInt = 10_000_000

  // scrollback-limit の usize は ghostty_config_get の対象外で読み戻せないため、テストは読み込み順序と diagnostics で確かめる。
  static let configuration = "scrollback-limit = \(scrollbackLimit)\n"
}
