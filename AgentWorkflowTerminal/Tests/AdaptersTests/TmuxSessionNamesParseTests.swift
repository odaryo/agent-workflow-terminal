import Foundation
import Testing

@testable import Adapters

@Suite("tmux session 一覧の名前復号")
struct TmuxSessionNamesParseTests {
  @Test("tmux 3.4 の fixture を target 用の正式名へ復号し、出力順を保つ")
  func decodesTmux34Fixture() throws {
    let output = try fixture(named: "tmux-3.4-list-sessions-hostile-names.txt")
    let result: TmuxSessionNameList = try TmuxSessionOperations.parseSessionNames(output: output)

    #expect(
      result.names == [
        #"a\\\$b"#,
        "awt-normal-1a2b3c4d",
        #"dol\$x"#,
        #"tab\tx"#,
        #"two\\\\bs"#,
        #"user\\back"#,
        "x$",
      ])
    #expect(result.undecodableLineCount == 0)
  }

  @Test("tmux 3.8 の fixture を target 用の正式名へ復号し、出力順を保つ")
  func decodesTmux38Fixture() throws {
    let output = try fixture(named: "tmux-3.8-list-sessions-hostile-names.txt")
    let result: TmuxSessionNameList = try TmuxSessionOperations.parseSessionNames(output: output)

    #expect(
      result.names == [
        #"a\\$b"#,
        "awt-normal-1a2b3c4d",
        "dol$x",
        #"two\\\\bs"#,
        #"user\\back"#,
        "x$",
      ])
    #expect(result.undecodableLineCount == 0)
  }

  @Test(
    "復号できない行だけを除いて数え、正常な行の順序を保つ",
    arguments: [#"bad\name"#, #"bad\\\name"#, #"bad\"#]
  )
  func skipsInvalidSessionNameEscape(invalidLine: String) throws {
    let output = "valid-before\n\(invalidLine)\nvalid-after\n"
    let result: TmuxSessionNameList = try TmuxSessionOperations.parseSessionNames(output: output)

    #expect(result.names == ["valid-before", "valid-after"])
    #expect(result.undecodableLineCount == 1)
  }

  @Test("複数の復号できない行をそれぞれ数え、正常な行の順序を保つ")
  func countsEveryUndecodableLine() throws {
    let output = ["first", #"bad\name"#, "second", #"bad\name"#, #"bad\"#, "third"]
      .joined(separator: "\n")
    let result: TmuxSessionNameList = try TmuxSessionOperations.parseSessionNames(output: output)

    #expect(result.names == ["first", "second", "third"])
    #expect(result.undecodableLineCount == 3)
  }

  @Test("全行が復号できなければ名前は空で、全行を復号できない行として数える")
  func skipsAllUndecodableLines() throws {
    let output = [#"bad\name"#, #"bad\\\name"#, #"bad\"#].joined(separator: "\n") + "\n"
    let result: TmuxSessionNameList = try TmuxSessionOperations.parseSessionNames(output: output)

    #expect(result.names.isEmpty)
    #expect(result.undecodableLineCount == 3)
  }

  @Test("空の出力は名前が空で、復号できない行はない")
  func parsesEmptyOutput() throws {
    let result: TmuxSessionNameList = try TmuxSessionOperations.parseSessionNames(output: "")

    #expect(result.names.isEmpty)
    #expect(result.undecodableLineCount == 0)
  }

  @Test("末尾の LF の有無で空の要素を作らない", arguments: ["first\nsecond", "first\nsecond\n"])
  func splitsSessionNamesOnLF(output: String) throws {
    let result: TmuxSessionNameList = try TmuxSessionOperations.parseSessionNames(output: output)

    #expect(result.names == ["first", "second"])
    #expect(result.undecodableLineCount == 0)
  }

  private func fixture(named name: String) throws -> String {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    )
    return try String(contentsOf: fixtureURL, encoding: .utf8)
  }
}
