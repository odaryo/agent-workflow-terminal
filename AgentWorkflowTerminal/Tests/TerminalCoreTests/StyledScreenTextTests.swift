import Foundation
import Testing

@testable import TerminalCore

@Suite("capture-pane -e -p の属性分解")
struct StyledScreenTextTests {
  private static func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/ScreenCapture"))
    return try String(contentsOf: url.appending(path: name), encoding: .utf8)
  }

  @Test(
    "-e -p から作った plain は -p とバイト一致する",
    arguments: ["idle", "working"]
  )
  func plainTextMatchesUnstyledCapture(_ scenario: String) throws {
    let styled = try Self.fixture("tmux-3.4-capture-pane-e-p-claude-2.1.263-\(scenario).esc.txt")
    let plain = try Self.fixture("tmux-3.4-capture-pane-p-claude-2.1.263-\(scenario).txt")
    #expect(StyledScreenText(capturedWithEscapeSequences: styled).plainText == plain)
  }

  @Test("入力欄のプレースホルダは dim、利用者の入力は dim でない")
  func inputBoxDimness() throws {
    let idle = StyledScreenText(
      capturedWithEscapeSequences: try Self.fixture(
        "tmux-3.4-capture-pane-e-p-claude-2.1.263-idle.esc.txt"))
    let working = StyledScreenText(
      capturedWithEscapeSequences: try Self.fixture(
        "tmux-3.4-capture-pane-e-p-claude-2.1.263-working.esc.txt"))
    func inputBox(_ screen: StyledScreenText) throws -> StyledScreenText.Line {
      try #require(screen.lines.last { $0.text.hasPrefix("❯\u{a0}") })
    }
    let placeholder = try inputBox(idle)
    #expect(placeholder.text == "❯\u{a0}cat a.txt")
    #expect(placeholder.isDim.suffix(9).allSatisfy { $0 })
    #expect(placeholder.isDim.prefix(2).allSatisfy { !$0 })
    #expect(try inputBox(working).isDim.allSatisfy { !$0 })
  }

  @Test("行末の rstrip は半角スペースとタブだけで、NBSP は残す")
  func trailingWhitespaceHandling() {
    let screen = StyledScreenText(capturedWithEscapeSequences: "a \t\nb\u{a0}\nc\u{a0} \n")
    #expect(screen.plainText == "a\nb\u{a0}\nc\u{a0}\n")
  }

  @Test("拡張色の引数 2 を dim と読み違えない")
  func extendedColorArgumentIsNotDim() {
    for sequence in ["\u{1b}[38;5;2m", "\u{1b}[38;2;2;2;2m", "\u{1b}[38:5:2m"] {
      let screen = StyledScreenText(capturedWithEscapeSequences: sequence + "x\n")
      #expect(screen.lines[0].isDim == [false], Comment(rawValue: sequence.debugDescription))
    }
  }

  @Test("dim は行をまたいで続き、リセットで解ける")
  func dimSpansLinesUntilReset() {
    let screen = StyledScreenText(capturedWithEscapeSequences: "\u{1b}[2ma\nb\u{1b}[0mc\n")
    #expect(screen.lines[0].isDim == [true])
    #expect(screen.lines[1].isDim == [true, false])
  }

  @Test("SGR 22 は dim を解く")
  func normalIntensityClearsDim() {
    let screen = StyledScreenText(capturedWithEscapeSequences: "\u{1b}[2ma\u{1b}[22mb\n")
    #expect(screen.lines[0].isDim == [true, false])
  }

  @Test("OSC は表示文字を残して除去する")
  func osc8HyperlinkIsRemoved() throws {
    let styled = try Self.fixture("tmux-3.4-capture-pane-e-p-claude-2.1.263-idle.esc.txt")
    let screen = StyledScreenText(capturedWithEscapeSequences: styled)
    #expect(styled.contains("\u{1b}]8;id="))
    #expect(!screen.plainText.contains("\u{1b}"))
    #expect(screen.plainText.contains("/rc"))
    // BEL 終端の OSC も同じ扱い。
    let bell = StyledScreenText(capturedWithEscapeSequences: "\u{1b}]0;title\u{07}x\n")
    #expect(bell.plainText == "x\n")
  }

  @Test("属性を1つも含まない捕捉は属性なしと分かる")
  func capturesWithoutStylingAreDetectable() {
    #expect(!StyledScreenText(capturedWithEscapeSequences: "❯\u{a0}cat a.txt\n").containsAnyStyling)
    #expect(
      StyledScreenText(capturedWithEscapeSequences: "\u{1b}[39m❯\u{a0}\n").containsAnyStyling)
  }
}
