import Adapters
import Foundation
import Testing

// inline の既知出力は tag 3.5a の configure.ac `AC_INIT([tmux], 3.5a)`、master の
// `AC_INIT([tmux], next-3.8)`、OpenBSD usr.bin/tmux/tmux.c の
// `xasprintf(&version, "openbsd-%s", u.release)` に基づく。
@Suite("tmux 版数の解釈と支援状況")
struct TmuxVersionTests {
  @Test(
    "版数出力を解釈する",
    arguments: [
      ("tmux 3.4\n", TmuxVersionParseResult.parsed(.init(major: 3, minor: 4))),
      ("tmux 3.5a\n", .parsed(.init(major: 3, minor: 5, suffix: "a"))),
      ("tmux 3.3a\n", .parsed(.init(major: 3, minor: 3, suffix: "a"))),
      ("tmux 3.7c\n", .parsed(.init(major: 3, minor: 7, suffix: "c"))),
      ("tmux 03.04\n", .parsed(.init(major: 3, minor: 4))),
      ("tmux next-3.6\n", .unparsable("tmux next-3.6\n")),
      ("tmux next-3.8\n", .unparsable("tmux next-3.8\n")),
      ("tmux master\n", .unparsable("tmux master\n")),
      ("tmux openbsd-7.5\n", .unparsable("tmux openbsd-7.5\n")),
      ("tmux next-3.6a\n", .unparsable("tmux next-3.6a\n")),
      ("", .unparsable("")),
      ("3.4\n", .unparsable("3.4\n")),
      ("tmux 3\n", .unparsable("tmux 3\n")),
      ("tmux 3.4 extra\n", .unparsable("tmux 3.4 extra\n")),
      ("tmux 3.4.1\n", .unparsable("tmux 3.4.1\n")),
      ("tmux 3.5A\n", .unparsable("tmux 3.5A\n")),
      ("tmux 3.5aa\n", .unparsable("tmux 3.5aa\n")),
      ("tmux 3.5-rc1\n", .unparsable("tmux 3.5-rc1\n")),
    ]
  )
  func parsesVersionOutput(versionOutput: String, expected: TmuxVersionParseResult) {
    #expect(TmuxVersion.parse(versionOutput: versionOutput) == expected)
  }

  @Test("tmux 3.4 の実測 fixture を解釈する")
  func parsesMeasuredVersionFixture() throws {
    // 採取: tmux 3.4 / `tmux -u -L <捨てsocket> -V`。
    let output = try fixture(named: "tmux-3.4-version.txt")

    #expect(TmuxVersion.parse(versionOutput: output) == .parsed(.init(major: 3, minor: 4)))
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
        .supportedWithWarnings(
          .init(major: 3, minor: 4),
          Set([.zeroWidthJoinerGraphemeWidth])
        )
      ),
      (
        TmuxVersion(major: 3, minor: 4, suffix: "a"),
        .supportedWithWarnings(
          .init(major: 3, minor: 4, suffix: "a"),
          Set([.zeroWidthJoinerGraphemeWidth])
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

  @Test(
    "解釈できない版数を unknown のまま返す",
    arguments: ["tmux master\n", "tmux next-3.8\n"]
  )
  func preservesUnknownVersionOutput(rawOutput: String) {
    #expect(
      TmuxVersion.support(for: .unparsable(rawOutput))
        == .unknown(rawOutput: rawOutput))
  }

  @Test(
    "表示用の版数文字列へ戻す",
    arguments: [
      (TmuxVersion(major: 3, minor: 5), "3.5"),
      (TmuxVersion(major: 3, minor: 5, suffix: "a"), "3.5a"),
      (TmuxVersion(major: 3, minor: 10), "3.10"),
    ]
  )
  func describesVersion(version: TmuxVersion, expected: String) {
    #expect(version.description == expected)
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
