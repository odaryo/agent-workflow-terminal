import Adapters
import Testing

@Suite("#751 highlight.js HTML の解釈")
struct HighlightJSMarkupTests {
  @Test("span の class と文書順を保持し、外側の文字には scope を付けない")
  func preservesClassesAndDocumentOrder() {
    #expect(
      HighlightJSMarkup.parse(
        "before<span class=\"a b\">x</span>between<span class=\"c\">y</span>after")
        == [
          HighlightJSRun(text: "before", scopes: []),
          HighlightJSRun(text: "x", scopes: [["a", "b"]]),
          HighlightJSRun(text: "between", scopes: []),
          HighlightJSRun(text: "y", scopes: [["c"]]),
          HighlightJSRun(text: "after", scopes: []),
        ])
  }

  @Test("入れ子の scope を外側から並べ、閉じた後は外側の scope に戻る")
  func preservesNestedScopes() {
    #expect(
      HighlightJSMarkup.parse("<span class=\"a b\">x<span class=\"c\">y</span>z</span>")
        == [
          HighlightJSRun(text: "x", scopes: [["a", "b"]]),
          HighlightJSRun(text: "y", scopes: [["a", "b"], ["c"]]),
          HighlightJSRun(text: "z", scopes: [["a", "b"]]),
        ])
  }

  @Test(
    "空の文字列や空の span から run を生成しない",
    arguments: [
      "", "<span class=\"a\"></span>", "<span class=\"a\"><span class=\"b\"></span></span>",
    ]
  )
  func omitsEmptyRuns(html: String) {
    #expect(HighlightJSMarkup.parse(html) == [])
  }

  @Test("文字を含む文書でも空の span の run を生成しない")
  func omitsEmptySpanBetweenText() throws {
    let runs = try #require(HighlightJSMarkup.parse("x<span class=\"a\"></span>y"))
    #expect(runs.allSatisfy { !$0.text.isEmpty && $0.scopes.isEmpty })
    #expect(runs.map(\.text).joined() == "xy")
  }

  @Test(
    "許可された5種の文字参照を1回だけ復号する",
    arguments: [
      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
      ("&#x27;", "'"), ("&amp;lt;", "&lt;"),
    ]
  )
  func decodesSupportedEntities(html: String, expected: String) {
    #expect(HighlightJSMarkup.parse(html) == [HighlightJSRun(text: expected, scopes: [])])
    #expect(
      HighlightJSMarkup.parse("<span class=\"a\">\(html)</span>")
        == [HighlightJSRun(text: expected, scopes: [["a"]])])
  }

  @Test(
    "仕様外の入力は途中まで成功しても結果全体を nil にする",
    arguments: [
      "&unknown;", "&apos;", "&#39;", "&#x41;", "&", "&amp", "<", ">", "a < b", "a > b",
      "<div>x</div>", "<br>", "<span class=\"a\" id=\"x\">x</span>",
      "<span id=\"x\">x</span>", "<span class=\"a\">x", "</span>",
      "<span class=\"a\"><span class=\"b\">x</span>",
      "<span class=\"a\">x</span></span>", "<span", "<span class=\"a\"", "</span",
    ]
  )
  func rejectsInvalidMarkup(html: String) {
    #expect(HighlightJSMarkup.parse(html) == nil)
    #expect(HighlightJSMarkup.parse("valid<span class=\"ok\">prefix</span>\(html)") == nil)
  }

  @Test("CRLF と改行をそのまま保持する")
  func preservesLineEndings() {
    #expect(
      HighlightJSMarkup.parse("\r\n<span class=\"a\">x\r\ny</span>\n")
        == [
          HighlightJSRun(text: "\r\n", scopes: []),
          HighlightJSRun(text: "x\r\ny", scopes: [["a"]]),
          HighlightJSRun(text: "\n", scopes: []),
        ])
  }

  @Test("書記素がタグ境界をまたいでも Unicode scalar ごとに scope を保持する")
  func preservesCombiningScalarAcrossTagBoundary() throws {
    let runs = try #require(HighlightJSMarkup.parse("<span class=\"a\">e</span>\u{0301}"))
    #expect(
      runs == [
        HighlightJSRun(text: "e", scopes: [["a"]]),
        HighlightJSRun(text: "\u{0301}", scopes: []),
      ])
    #expect(runs.map(\.text).joined().unicodeScalars.map(\.value) == [0x65, 0x301])
  }

  @Test("絵文字・補助平面の文字・日本語の scalar を壊さない")
  func preservesUnicodeScalars() throws {
    let html = "👩🏽‍💻<span class=\"a\">𠮷😀&amp;日本語</span>\r\n"
    let runs = try #require(HighlightJSMarkup.parse(html))
    #expect(
      runs == [
        HighlightJSRun(text: "👩🏽‍💻", scopes: []),
        HighlightJSRun(text: "𠮷😀&日本語", scopes: [["a"]]),
        HighlightJSRun(text: "\r\n", scopes: []),
      ])
    #expect(
      runs.map(\.text).joined().unicodeScalars.map(\.value)
        == "👩🏽‍💻𠮷😀&日本語\r\n".unicodeScalars.map(\.value))
  }

  @Test("highlight.js 11.11.1 の実測出力を復号し元のコードを復元する")
  func parsesMeasuredOutput() throws {
    let html =
      "<span class=\"hljs-keyword\">class</span> <span class=\"hljs-title class_\">A</span>"
      + "&lt;<span class=\"hljs-type\">T</span>&gt; { "
      + "<span class=\"hljs-string\">&quot;a&amp;b&#x27;&quot;</span> "
      + "<span class=\"hljs-comment\">// x</span>\n}}\n"
      + "<span class=\"hljs-string\">`a<span class=\"hljs-subst\">${"
      + "<span class=\"hljs-number\">1</span>+<span class=\"hljs-number\">2</span>}</span>`</span>"
    let runs = try #require(HighlightJSMarkup.parse(html))
    #expect(
      runs == [
        HighlightJSRun(text: "class", scopes: [["hljs-keyword"]]),
        HighlightJSRun(text: " ", scopes: []),
        HighlightJSRun(text: "A", scopes: [["hljs-title", "class_"]]),
        HighlightJSRun(text: "<", scopes: []),
        HighlightJSRun(text: "T", scopes: [["hljs-type"]]),
        HighlightJSRun(text: "> { ", scopes: []),
        HighlightJSRun(text: "\"a&b'\"", scopes: [["hljs-string"]]),
        HighlightJSRun(text: " ", scopes: []),
        HighlightJSRun(text: "// x", scopes: [["hljs-comment"]]),
        HighlightJSRun(text: "\n}}\n", scopes: []),
        HighlightJSRun(text: "`a", scopes: [["hljs-string"]]),
        HighlightJSRun(text: "${", scopes: [["hljs-string"], ["hljs-subst"]]),
        HighlightJSRun(text: "1", scopes: [["hljs-string"], ["hljs-subst"], ["hljs-number"]]),
        HighlightJSRun(text: "+", scopes: [["hljs-string"], ["hljs-subst"]]),
        HighlightJSRun(text: "2", scopes: [["hljs-string"], ["hljs-subst"], ["hljs-number"]]),
        HighlightJSRun(text: "}", scopes: [["hljs-string"], ["hljs-subst"]]),
        HighlightJSRun(text: "`", scopes: [["hljs-string"]]),
      ])
    #expect(runs.map(\.text).joined() == "class A<T> { \"a&b'\" // x\n}}\n`a${1+2}`")
  }
}
