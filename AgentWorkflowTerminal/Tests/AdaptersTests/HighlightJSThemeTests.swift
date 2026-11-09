import Adapters
import Testing

@Suite("#751 highlight.js テーマ CSS の解釈と適用")
struct HighlightJSThemeTests {
  private static let atomOneDark = """
    /* header comment */
    .hljs{display:block;overflow-x:auto;padding:.5em;color:#abb2bf;background:#282c34}
    .hljs-comment,.hljs-quote{color:#5c6370;font-style:italic}
    .hljs-string,.hljs-regexp,.hljs-addition,.hljs-attribute,.hljs-meta.hljs-string{color:#98c379}
    .hljs-symbol,.hljs-bullet,.hljs-link,.hljs-meta,.hljs-selector-id,.hljs-title{color:#61aeee}
    .hljs-built_in,.hljs-title.class_,.hljs-class.hljs-title{color:#e6c07b}
    .hljs-strong{font-weight:bold}
    .hljs-link{text-decoration:underline}
    """

  private static let baseRule = ".hljs{color:#abb2bf;background:#282c34}"

  @Test("実物の minify 済み CSS から基底色と背景色を取得する")
  func parsesMeasuredTheme() throws {
    let theme = try #require(HighlightJSTheme.parse(css: Self.atomOneDark))
    #expect(theme.baseColor == HighlightJSColor(red: 171, green: 178, blue: 191))
    #expect(theme.backgroundColor == HighlightJSColor(red: 40, green: 44, blue: 52))
  }

  @Test(
    "基底の color または背景色がなければ nil を返す",
    arguments: [
      "", ".hljs{color:#123}", ".hljs{background:#fff}",
      ".hljs{background-color:#fff}", ".token{color:#123;background:#fff}",
      ".hljs{color:red;background:#fff}", ".hljs{color:#123;background:red}",
    ]
  )
  func requiresBothBaseColors(css: String) {
    #expect(HighlightJSTheme.parse(css: css) == nil)
  }

  @Test(
    "background と background-color の両方を解釈する",
    arguments: ["background", "background-color"]
  )
  func acceptsBackgroundProperties(property: String) throws {
    let theme = try #require(
      HighlightJSTheme.parse(css: ".hljs{color:#3F6E74;\(property):#fff}"))
    #expect(theme.baseColor == HighlightJSColor(red: 63, green: 110, blue: 116))
    #expect(theme.backgroundColor == HighlightJSColor(red: 255, green: 255, blue: 255))
  }

  @Test(
    "3桁と6桁の16進色を大文字小文字にかかわらず解釈する",
    arguments: [
      ("#fff", HighlightJSColor(red: 255, green: 255, blue: 255)),
      ("#aBc", HighlightJSColor(red: 170, green: 187, blue: 204)),
      ("#3F6E74", HighlightJSColor(red: 63, green: 110, blue: 116)),
      ("#3f6e74", HighlightJSColor(red: 63, green: 110, blue: 116)),
    ]
  )
  func parsesHexColors(value: String, expected: HighlightJSColor) throws {
    let theme = try #require(
      HighlightJSTheme.parse(css: ".hljs{color:\(value);background-color:\(value)}"))
    #expect(theme.baseColor == expected)
    #expect(theme.backgroundColor == expected)
  }

  @Test("複数行コメントと規則の間のコメントを無視する")
  func ignoresComments() throws {
    let css = """
      /* .hljs{color:red}
         .token{color:#f00} */
      .hljs{color:#123;background:#fff}
      /* .token{font-weight:bold} */
      .token{color:#3F6E74}
      /* trailing comment */
      """
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(theme.baseColor == HighlightJSColor(red: 17, green: 34, blue: 51))
    #expect(theme.backgroundColor == HighlightJSColor(red: 255, green: 255, blue: 255))
    #expect(
      theme.style(forScopes: [["token"]])
        == HighlightJSStyle(color: HighlightJSColor(red: 63, green: 110, blue: 116)))
  }

  @Test(
    "非対応の色は宣言だけ無視し、他の宣言と以前の有効な色を残す",
    arguments: ["red", "rgb(1,2,3)", "#12", "#1234", "#12345", "#12345678", "#ggg"]
  )
  func ignoresUnsupportedColors(value: String) throws {
    let css =
      Self.baseRule
      + ".hljs{color:\(value);background:\(value)}"
      + ".token{color:#123;background-color:#456}"
      + ".token{color:\(value);background-color:\(value);font-style:italic;display:block}"
      + ".other{color:\(value);font-weight:bold}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(theme.baseColor == HighlightJSColor(red: 171, green: 178, blue: 191))
    #expect(theme.backgroundColor == HighlightJSColor(red: 40, green: 44, blue: 52))
    #expect(
      theme.style(forScopes: [["token"]])
        == HighlightJSStyle(
          color: HighlightJSColor(red: 17, green: 34, blue: 51),
          backgroundColor: HighlightJSColor(red: 68, green: 85, blue: 102), isItalic: true))
    #expect(theme.style(forScopes: [["other"]]) == HighlightJSStyle(isBold: true))
  }

  @Test("空の scope・未知の class・hljs 自体はすべて既定の style になる")
  func excludesBaseRuleFromStyles() throws {
    let theme = try #require(
      HighlightJSTheme.parse(
        css: Self.baseRule + ".hljs{font-weight:bold;font-style:italic;text-decoration:underline}"))
    #expect(theme.style(forScopes: []) == HighlightJSStyle())
    #expect(theme.style(forScopes: [["unknown"]]) == HighlightJSStyle())
    #expect(theme.style(forScopes: [["hljs"]]) == HighlightJSStyle())
  }

  @Test(
    "コンマで列挙された各 class に実物のテーマを適用する",
    arguments: [
      "hljs-string", "hljs-regexp", "hljs-addition", "hljs-attribute",
    ]
  )
  func matchesCommaSeparatedSelectors(scope: String) throws {
    let theme = try #require(HighlightJSTheme.parse(css: Self.atomOneDark))
    #expect(
      theme.style(forScopes: [[scope]])
        == HighlightJSStyle(color: HighlightJSColor(red: 152, green: 195, blue: 121)))
  }

  @Test(
    "不正なセレクタだけ無視し同じ規則の他のセレクタを生かす",
    arguments: [".outer .token", ".outer\t.token", ".token:hover", "span.token", "#token"]
  )
  func ignoresUnsupportedSelectors(selector: String) throws {
    let css = Self.baseRule + "\(selector), .valid{color:#123;font-weight:bold}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(
      theme.style(forScopes: [["valid"]])
        == HighlightJSStyle(color: HighlightJSColor(red: 17, green: 34, blue: 51), isBold: true))
    #expect(theme.style(forScopes: [["outer", "token"]]) == HighlightJSStyle())
    #expect(theme.style(forScopes: [["outer"], ["token"]]) == HighlightJSStyle())
  }

  @Test(
    "複合 class は同じ span にすべて含まれるときだけ一致し class 順には依存しない",
    arguments: [
      (["hljs-title", "class_"], HighlightJSColor(red: 230, green: 192, blue: 123)),
      (["class_", "extra", "hljs-title"], HighlightJSColor(red: 230, green: 192, blue: 123)),
      (["hljs-class", "hljs-title"], HighlightJSColor(red: 230, green: 192, blue: 123)),
      (["hljs-title", "function_"], HighlightJSColor(red: 97, green: 174, blue: 238)),
    ]
  )
  func matchesCompoundClasses(classes: [String], expected: HighlightJSColor) throws {
    let theme = try #require(HighlightJSTheme.parse(css: Self.atomOneDark))
    #expect(theme.style(forScopes: [classes]) == HighlightJSStyle(color: expected))
  }

  @Test("同じ span ではプロパティごとに class 数が多いセレクタを優先する")
  func resolvesSpecificityPerProperty() throws {
    let css =
      Self.baseRule
      + ".a.b{color:#123;font-style:italic}"
      + ".a{color:#456;font-style:normal;font-weight:bold}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(
      theme.style(forScopes: [["a", "b"]])
        == HighlightJSStyle(
          color: HighlightJSColor(red: 17, green: 34, blue: 51), isBold: true, isItalic: true))
  }

  @Test("class 数が同じなら CSS で後の規則がプロパティごとに優先する")
  func resolvesSourceOrderPerProperty() throws {
    let css =
      Self.baseRule
      + ".a{color:#123;font-style:italic}"
      + ".b{color:#456;font-weight:bold}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    let expected = HighlightJSStyle(
      color: HighlightJSColor(red: 68, green: 85, blue: 102), isBold: true, isItalic: true)
    #expect(theme.style(forScopes: [["a", "b"]]) == expected)
    #expect(theme.style(forScopes: [["b", "a"]]) == expected)
  }

  @Test("入れ子の class を複合セレクタとして一致させない")
  func doesNotCombineNestedClasses() throws {
    let css =
      Self.baseRule
      + ".hljs-meta{color:#61aeee}"
      + ".hljs-string{color:#98c379}"
      + ".hljs-meta.hljs-string{color:#f00;font-weight:bold}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(
      theme.style(forScopes: [["hljs-meta"], ["hljs-string"]])
        == HighlightJSStyle(color: HighlightJSColor(red: 152, green: 195, blue: 121)))
    #expect(
      theme.style(forScopes: [["hljs-meta", "hljs-string"]])
        == HighlightJSStyle(color: HighlightJSColor(red: 255, green: 0, blue: 0), isBold: true))
  }

  @Test("内側が指定したプロパティだけ上書きし外側の他のプロパティを継承する")
  func inheritsUnspecifiedProperties() throws {
    let css =
      Self.baseRule
      + ".inner{color:#456}"
      + ".outer.extra{color:#123;background:#abc;font-style:italic;"
      + "font-weight:bold;text-decoration:underline}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(
      theme.style(forScopes: [["outer", "extra"], ["unknown"], ["inner"]])
        == HighlightJSStyle(
          color: HighlightJSColor(red: 68, green: 85, blue: 102),
          backgroundColor: HighlightJSColor(red: 170, green: 187, blue: 204),
          isBold: true, isItalic: true, isUnderlined: true))
  }

  @Test("font-weight と font-style の normal で継承した装飾を解除する")
  func resetsInheritedFontStyles() throws {
    let css =
      Self.baseRule
      + ".outer{font-weight:bold;font-style:italic;text-decoration:underline}"
      + ".inner{font-weight:normal;font-style:normal}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(
      theme.style(forScopes: [["outer"], ["inner"]]) == HighlightJSStyle(isUnderlined: true))
  }

  @Test("同じ span でも後の normal 宣言で bold と italic を解除する")
  func resetsFontStylesBySourceOrder() throws {
    let css =
      Self.baseRule
      + ".token{font-weight:bold;font-style:italic}"
      + ".token{font-weight:normal;font-style:normal}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(theme.style(forScopes: [["token"]]) == HighlightJSStyle())
  }

  @Test("実物のコメント・strong・link の各装飾を解釈する")
  func parsesMeasuredDecorations() throws {
    let theme = try #require(HighlightJSTheme.parse(css: Self.atomOneDark))
    let commentStyle = HighlightJSStyle(
      color: HighlightJSColor(red: 92, green: 99, blue: 112), isItalic: true)
    #expect(theme.style(forScopes: [["hljs-comment"]]) == commentStyle)
    #expect(theme.style(forScopes: [["hljs-quote"]]) == commentStyle)
    #expect(theme.style(forScopes: [["hljs-strong"]]) == HighlightJSStyle(isBold: true))
    #expect(
      theme.style(forScopes: [["hljs-link"]])
        == HighlightJSStyle(
          color: HighlightJSColor(red: 97, green: 174, blue: 238), isUnderlined: true))
  }

  @Test("xcode.css の短縮背景色・複合セレクタ・formula の背景色を解釈する")
  func parsesXcodeThemeRules() throws {
    let css =
      ".hljs{color:#000;background:#fff}"
      + ".xml.hljs-meta{color:#c0c0c0}"
      + ".hljs-formula{background-color:#eee;font-style:italic}"
    let theme = try #require(HighlightJSTheme.parse(css: css))
    #expect(theme.backgroundColor == HighlightJSColor(red: 255, green: 255, blue: 255))
    #expect(
      theme.style(forScopes: [["xml", "hljs-meta"]])
        == HighlightJSStyle(color: HighlightJSColor(red: 192, green: 192, blue: 192)))
    #expect(theme.style(forScopes: [["xml"], ["hljs-meta"]]) == HighlightJSStyle())
    #expect(
      theme.style(forScopes: [["hljs-formula"]])
        == HighlightJSStyle(
          backgroundColor: HighlightJSColor(red: 238, green: 238, blue: 238), isItalic: true))
  }
}
