enum GhosttyProductDefaults {
  /// 単位は byte。libghostty のコンパイル既定に依存させない (設計書 §4.4)。
  static let scrollbackLimit: UInt = 10_000_000

  // scrollback-limit は usize で ghostty_config_get の対象外なので読み戻せない。
  // テストが守るのは読み込み順序 (font-size で代用)、libghostty が中身を受け付けること
  // (diagnostics)、値の固定の3つ。本番で製品既定を渡すことは GhosttyRuntime の呼び出し
  // 1か所に依存し、テストでは守れない。
  static let configuration = "scrollback-limit = \(scrollbackLimit)\n"
}
