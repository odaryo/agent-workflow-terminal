import Foundation
import Testing

@testable import Adapters

@Suite("tmux session 一覧の名前復号")
struct TmuxSessionNamesParseTests {
  @Test("tmux 3.4 の fixture を target 用の正式名へ復号し、出力順を保つ")
  func decodesTmux34Fixture() throws {
    let output = try fixture(named: "tmux-3.4-list-sessions-hostile-names.txt")

    #expect(
      try TmuxSessionOperations.parseSessionNames(output: output) == [
        #"a\\\$b"#,
        "awt-normal-1a2b3c4d",
        #"dol\$x"#,
        #"tab\tx"#,
        #"two\\\\bs"#,
        #"user\\back"#,
        "x$",
      ])
  }

  @Test("tmux 3.8 の fixture を target 用の正式名へ復号し、出力順を保つ")
  func decodesTmux38Fixture() throws {
    let output = try fixture(named: "tmux-3.8-list-sessions-hostile-names.txt")

    #expect(
      try TmuxSessionOperations.parseSessionNames(output: output) == [
        #"a\\$b"#,
        "awt-normal-1a2b3c4d",
        "dol$x",
        #"two\\\\bs"#,
        #"user\\back"#,
        "x$",
      ])
  }

  @Test(
    "復号できない行が混ざった一覧は原文を保持したエラーになる",
    arguments: [#"bad\name"#, #"bad\\\name"#, #"bad\"#]
  )
  func rejectsInvalidSessionNameEscape(invalidLine: String) {
    let output = "valid-before\n\(invalidLine)\nvalid-after\n"

    #expect(throws: TmuxSessionOperationError.invalidSessionNameEscape(invalidLine)) {
      try TmuxSessionOperations.parseSessionNames(output: output)
    }
  }

  @Test("空の出力は空配列になる")
  func parsesEmptyOutput() throws {
    #expect(try TmuxSessionOperations.parseSessionNames(output: "").isEmpty)
  }

  @Test("末尾の LF の有無で空の要素を作らない", arguments: ["first\nsecond", "first\nsecond\n"])
  func splitsSessionNamesOnLF(output: String) throws {
    #expect(try TmuxSessionOperations.parseSessionNames(output: output) == ["first", "second"])
  }

  private func fixture(named name: String) throws -> String {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    )
    return try String(contentsOf: fixtureURL, encoding: .utf8)
  }
}
