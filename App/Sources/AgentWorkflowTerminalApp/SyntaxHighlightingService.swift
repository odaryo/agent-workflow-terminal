import AppKit
import Highlighter
import SwiftUI

actor SyntaxHighlightingService {
  struct HighlightedCode: Sendable {
    let text: AttributedString
    let background: Color
  }

  static let shared = SyntaxHighlightingService()

  /// 計測 (release ビルド、Apple Silicon、同梱 highlight.js 11.11.1、Swift ソース):
  /// 64 KiB = 0.19 s / 128 KiB = 0.36 s / 256 KiB = 0.77 s / 1 MiB = 2.87 s / 2 MiB = 5.72 s と
  /// 入力サイズにほぼ比例する。1 秒を超えて色が付かない状態を見せないため 256 KiB で切る。
  /// §7.2 の警告閾値 (1 MiB) より小さいので、その間のファイルは素のまま表示される。
  static let maximumByteCount = 262_144

  private static let lightThemeName = "xcode"
  private static let darkThemeName = "atom-one-dark"
  private static let fontName = "Menlo"
  private static let fontSize: CGFloat = 12

  private var highlighter: Highlighter?
  private var isHighlighterUnavailable = false
  private var themeIsDark: Bool?

  func highlight(_ code: String, language: String, isDark: Bool) -> HighlightedCode? {
    guard let highlighter = highlighter(isDark: isDark) else { return nil }
    guard let attributed = highlighter.highlight(code, as: language) else { return nil }
    guard let background = highlighter.theme.themeBackgroundColour else { return nil }
    return HighlightedCode(
      text: AttributedString(attributed), background: Color(nsColor: background))
  }

  private func highlighter(isDark: Bool) -> Highlighter? {
    guard !isHighlighterUnavailable else { return nil }
    let highlighter: Highlighter
    if let existing = self.highlighter {
      highlighter = existing
    } else {
      // JavaScriptCore の context と highlight.js の評価はここで一度だけ行う。
      guard let created = Highlighter() else {
        isHighlighterUnavailable = true
        return nil
      }
      highlighter = created
      self.highlighter = created
    }
    if themeIsDark != isDark {
      highlighter.setTheme(
        isDark ? Self.darkThemeName : Self.lightThemeName,
        withFont: Self.fontName,
        ofSize: Self.fontSize)
      themeIsDark = isDark
    }
    return highlighter
  }
}
