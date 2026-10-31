import Foundation
import Testing

@testable import GhosttyRenderer

struct TerminalDropTextTests {
  @Test(arguments: [
    ("/tmp/a.png", "/tmp/a.png"),
    ("/tmp/space name.png", "/tmp/space\\ name.png"),
    ("/tmp/日本語 画像.png", "/tmp/日本語\\ 画像.png"),
  ])
  func escapesPaths(path: String, expected: String) {
    #expect(TerminalDropText.text(for: [URL(fileURLWithPath: path)]) == expected)
  }

  @Test(arguments: [
    (#"/tmp/a$(x).png"#, #"/tmp/a\$\(x\).png"#),
    (#"/tmp/^a.png"#, #"/tmp/\^a.png"#),
    (#"/tmp/~a b.png"#, #"/tmp/\~a\ b.png"#),
    (#"/tmp/a'b"c.png"#, #"/tmp/a\'b\"c.png"#),
    (#"/tmp/a\b`c.png"#, #"/tmp/a\\b\`c.png"#),
    (##"/tmp/a!#&;|b.png"##, ##"/tmp/a\!\#\&\;\|b.png"##),
    (#"/tmp/a*?[x]{y}.png"#, #"/tmp/a\*\?\[x\]\{y\}.png"#),
    (#"/tmp/a<>=%b.png"#, #"/tmp/a\<\>\=\%b.png"#),
  ])
  func escapesShellSyntax(path: String, expected: String) {
    #expect(TerminalDropText.text(for: [URL(fileURLWithPath: path)]) == expected)
  }

  @Test(arguments: [
    "/tmp/a\u{0085}b.png",
    "/tmp/a\u{2028}b.png",
  ])
  func preservesUnicodeSeparators(path: String) {
    #expect(TerminalDropText.text(for: [URL(fileURLWithPath: path)]) == path)
  }

  @Test func joinsFilesWithoutTrailingWhitespace() {
    let urls = ["/tmp/a.png", "/tmp/space name.png"].map { URL(fileURLWithPath: $0) }
    #expect(TerminalDropText.text(for: urls) == "/tmp/a.png /tmp/space\\ name.png")
  }

  // U+0000 は除く: ファイル名に入り得ず、URL が `%00` に置き換えるのでこの経路へ届かない。
  @Test(arguments: Array(UInt32(1)...UInt32(31)) + [127])
  func excludesControlCharacters(value: UInt32) throws {
    let scalar = try #require(Unicode.Scalar(value))
    let invalid = URL(fileURLWithPath: "/tmp/a\(scalar)b.png")
    let valid = URL(fileURLWithPath: "/tmp/valid.png")
    #expect(TerminalDropText.text(for: [invalid, valid]) == "/tmp/valid.png")
    #expect(TerminalDropText.text(for: [invalid]) == nil)
  }

  @Test func excludesNewlinesAmongMultipleFiles() {
    let urls = ["/tmp/a.png", "/tmp/new\nline.png", "/tmp/b.png"].map {
      URL(fileURLWithPath: $0)
    }
    #expect(TerminalDropText.text(for: urls) == "/tmp/a.png /tmp/b.png")
  }

  @Test func emptyInputReturnsNil() {
    #expect(TerminalDropText.text(for: []) == nil)
  }
}
