import Testing

@testable import AgentWorkflowTerminalApp

@Suite("Issue #812 Overview メニューの全文折り返し")
struct OverviewMenuLinesTests {
  @Test("幅ちょうどの ASCII は1行に収まる")
  func exactASCIIWidth() {
    let text = String(repeating: "a", count: 60)
    #expect(overviewMenuLines(text) == [text])
  }

  @Test("ASCII の文は最後の空白で折り返し、行端の空白を除く")
  func wrapsAtLastSpace() {
    #expect(
      overviewMenuLines("one two three four", maxWidth: 10) == ["one two", "three four"])
  }

  @Test("行の前後の半角空白を除く")
  func trimsSpaces() {
    #expect(overviewMenuLines("  one two  ") == ["one two"])
    #expect(overviewMenuLines("one   two three", maxWidth: 8) == ["one", "two", "three"])
  }

  @Test("空白の無い ASCII の語は幅で切る")
  func wrapsLongWord() {
    #expect(overviewMenuLines("abcdefghijk", maxWidth: 4) == ["abcd", "efgh", "ijk"])
  }

  @Test("全角31文字は30文字と1文字に分かれる")
  func fullWidthCharacters() {
    #expect(
      overviewMenuLines(String(repeating: "あ", count: 31))
        == [String(repeating: "あ", count: 30), "あ"])
  }

  @Test("全角と ASCII はそれぞれ幅2と幅1で数える")
  func mixedWidths() {
    #expect(overviewMenuLines("あabいうcd", maxWidth: 6) == ["あabい", "うcd"])
  }

  @Test("結合文字を分割しない")
  func combiningCharacters() {
    let combined = "か\u{3099}"
    #expect(overviewMenuLines("a" + combined + "b", maxWidth: 3) == ["a" + combined, "b"])
  }

  @Test("ZWJ の絵文字を幅2で数え、分割しない")
  func joinedEmoji() {
    let family = "👨‍👩‍👧"
    #expect(overviewMenuLines("a" + family + "b", maxWidth: 3) == ["a" + family, "b"])
  }

  @Test("空文字と半角空白だけの入力は行を返さない", arguments: ["", " ", "     "])
  func emptyInput(text: String) {
    #expect(overviewMenuLines(text).isEmpty)
  }
}
