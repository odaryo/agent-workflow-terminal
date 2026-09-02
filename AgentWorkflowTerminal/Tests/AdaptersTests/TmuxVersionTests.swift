import Adapters
import Testing

@Suite("tmux 版数の解釈と支援状況")
struct TmuxVersionTests {
  @Test(
    "版数出力を解釈する",
    arguments: [
      ("tmux 3.4\n", TmuxVersionParseResult.parsed(.init(major: 3, minor: 4))),
      ("tmux 3.5a\n", .parsed(.init(major: 3, minor: 5, suffix: "a"))),
      ("tmux 3.3a\n", .parsed(.init(major: 3, minor: 3, suffix: "a"))),
      ("tmux next-3.6\n", .parsed(.init(major: 3, minor: 6))),
      ("tmux master\n", .unparsable("tmux master\n")),
      ("tmux openbsd-7.5\n", .unparsable("tmux openbsd-7.5\n")),
      ("tmux next-3.6a\n", .unparsable("tmux next-3.6a\n")),
      ("", .unparsable("")),
      ("3.4\n", .unparsable("3.4\n")),
      ("tmux 3\n", .unparsable("tmux 3\n")),
      ("tmux 3.4 extra\n", .unparsable("tmux 3.4 extra\n")),
    ]
  )
  func parsesVersionOutput(versionOutput: String, expected: TmuxVersionParseResult) {
    #expect(TmuxVersion.parse(versionOutput: versionOutput) == expected)
  }

  @Test("前後の空白と末尾改行を無視する")
  func ignoresSurroundingWhitespace() {
    #expect(
      TmuxVersion.parse(versionOutput: " \t tmux 3.5a\n ")
        == .parsed(.init(major: 3, minor: 5, suffix: "a")))
  }

  @Test(
    "major、minor、suffix の順に数値と文字で比較する",
    arguments: [
      (TmuxVersion(major: 3, minor: 4), TmuxVersion(major: 3, minor: 5)),
      (TmuxVersion(major: 3, minor: 5), TmuxVersion(major: 3, minor: 5, suffix: "a")),
      (
        TmuxVersion(major: 3, minor: 5, suffix: "a"),
        TmuxVersion(major: 3, minor: 5, suffix: "b")
      ),
      (TmuxVersion(major: 3, minor: 9), TmuxVersion(major: 3, minor: 10)),
    ]
  )
  func comparesVersions(lower: TmuxVersion, higher: TmuxVersion) {
    #expect(lower < higher)
  }

  @Test(
    "版数の境界から支援状況を判定する",
    arguments: [
      (
        TmuxVersion(major: 3, minor: 3, suffix: "a"),
        TmuxVersionSupport.unsupported(
          .init(major: 3, minor: 3, suffix: "a"),
          minimum: .init(major: 3, minor: 4)
        )
      ),
      (
        TmuxVersion(major: 3, minor: 4),
        .supportedWithLimitations(
          .init(major: 3, minor: 4),
          [.zeroWidthJoinerGraphemeWidth]
        )
      ),
      (
        TmuxVersion(major: 3, minor: 4, suffix: "a"),
        .supportedWithLimitations(
          .init(major: 3, minor: 4, suffix: "a"),
          [.zeroWidthJoinerGraphemeWidth]
        )
      ),
      (TmuxVersion(major: 3, minor: 5), .supported(.init(major: 3, minor: 5))),
      (
        TmuxVersion(major: 3, minor: 5, suffix: "a"),
        .supported(.init(major: 3, minor: 5, suffix: "a"))
      ),
      (TmuxVersion(major: 4, minor: 0), .supported(.init(major: 4, minor: 0))),
    ]
  )
  func determinesSupport(version: TmuxVersion, expected: TmuxVersionSupport) {
    #expect(TmuxVersion.support(for: .parsed(version)) == expected)
  }

  @Test("解釈できない版数を unknown のまま返す")
  func preservesUnknownVersionOutput() {
    #expect(
      TmuxVersion.support(for: .unparsable("tmux master\n"))
        == .unknown(rawOutput: "tmux master\n"))
  }
}
