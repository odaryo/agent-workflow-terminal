import Adapters
import Foundation
import Testing

@Suite("§7.3 App に同梱した highlight.js テーマ CSS の解釈")
struct HighlightJSRepositoryThemeTests {
  private static let resourceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/highlight-js")

  private struct RepositoryThemeCase: Sendable {
    let filename: String
    let baseColor: HighlightJSColor
    let backgroundColor: HighlightJSColor
    let keywordColor: HighlightJSColor
    let stringColor: HighlightJSColor
    let commentColor: HighlightJSColor
    let classTitleColor: HighlightJSColor
    let italicComment: Bool
  }

  @Test(
    "#756 リポジトリのテーマ CSS 全文から基底色と主要 scope の属性を取得する",
    arguments: [
      RepositoryThemeCase(
        filename: "xcode.css",
        baseColor: HighlightJSColor(red: 0, green: 0, blue: 0),
        backgroundColor: HighlightJSColor(red: 255, green: 255, blue: 255),
        keywordColor: HighlightJSColor(red: 170, green: 13, blue: 145),
        stringColor: HighlightJSColor(red: 196, green: 26, blue: 22),
        commentColor: HighlightJSColor(red: 0, green: 116, blue: 0),
        classTitleColor: HighlightJSColor(red: 92, green: 38, blue: 153), italicComment: false
      ),
      RepositoryThemeCase(
        filename: "atom-one-dark.css",
        baseColor: HighlightJSColor(red: 171, green: 178, blue: 191),
        backgroundColor: HighlightJSColor(red: 40, green: 44, blue: 52),
        keywordColor: HighlightJSColor(red: 198, green: 120, blue: 221),
        stringColor: HighlightJSColor(red: 152, green: 195, blue: 121),
        commentColor: HighlightJSColor(red: 92, green: 99, blue: 112),
        classTitleColor: HighlightJSColor(red: 230, green: 192, blue: 123), italicComment: true
      ),
    ]
  )
  private func parsesRepositoryTheme(themeCase: RepositoryThemeCase) throws {
    let css = try String(
      contentsOf: Self.resourceDirectory.appendingPathComponent(themeCase.filename),
      encoding: .utf8)
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(theme.baseColor == themeCase.baseColor)
    #expect(theme.backgroundColor == themeCase.backgroundColor)
    #expect(
      theme.style(forScopes: [["hljs-keyword"]]) == HighlightJSStyle(color: themeCase.keywordColor))
    #expect(
      theme.style(forScopes: [["hljs-string"]]) == HighlightJSStyle(color: themeCase.stringColor))
    #expect(
      theme.style(forScopes: [["hljs-comment"]])
        == HighlightJSStyle(color: themeCase.commentColor, isItalic: themeCase.italicComment))
    #expect(
      theme.style(forScopes: [["hljs-title", "class_"]])
        == HighlightJSStyle(color: themeCase.classTitleColor))
    #expect(theme.style(forScopes: [["hljs-strong"]]) == HighlightJSStyle(isBold: true))
  }
}
