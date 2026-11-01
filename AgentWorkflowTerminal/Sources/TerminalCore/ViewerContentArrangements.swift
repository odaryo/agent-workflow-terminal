public enum ViewerContentArrangement: String, Sendable, Hashable, CaseIterable, Codable {
  case sideBySide
  case stacked
}

public struct ViewerContentArrangements: Sendable, Hashable, Codable {
  public var code: ViewerContentArrangement
  public var diff: ViewerContentArrangement

  public static let defaults = Self()

  public init(
    code: ViewerContentArrangement = .sideBySide, diff: ViewerContentArrangement = .stacked
  ) {
    self.code = code
    self.diff = diff
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case diff
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // 並びは再起動をまたいで保存する (§6.1)。保存値の片方のキーが欠けている・未知の値でも、
    // もう片方の選択を失わないよう、キー単位で既定値へ戻す。データ自体が JSON の辞書として
    // 読めない場合は throw するので、呼び出し側で既定値に包む。
    code =
      (try? container.decode(ViewerContentArrangement.self, forKey: .code)) ?? Self.defaults.code
    diff =
      (try? container.decode(ViewerContentArrangement.self, forKey: .diff)) ?? Self.defaults.diff
  }
}
