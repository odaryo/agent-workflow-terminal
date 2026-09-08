/// 端末がキーボードの first responder を取りに行ってよいかの指示 (Issue #278)。
///
/// `nil` を渡すこと (= このタブは表示されていない) と「今は取るな」を、別の値として分けて
/// 表す。ひとつの `nil` に兼ねさせると、`GhosttySurfaceView` が適用済みの要求を忘れる側の
/// 意味に引きずられ、テキスト入力の主張が解けた瞬間に古い要求で first responder を奪い返す。
public struct TerminalFocusRequest: Equatable, Sendable {
  /// 値そのものに意味は無く、変わったことだけが「取り直せ」を表す。
  public let token: Int
  /// キーボードを主張しているテキスト入力が Drawer 内に無いこと。
  public let isTerminalAllowed: Bool

  public init(token: Int, isTerminalAllowed: Bool) {
    self.token = token
    self.isTerminalAllowed = isTerminalAllowed
  }
}
