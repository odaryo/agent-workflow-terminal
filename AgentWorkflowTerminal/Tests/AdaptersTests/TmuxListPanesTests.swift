import Foundation
import Testing

@testable import Adapters
@testable import TerminalCore

@Suite("tmux list-panes 出力のパース")
struct TmuxListPanesTests {

  @Test("フォーマットは pane 状態の取得に必要な8フィールドを Unit Separator で区切る")
  func formatContainsRequiredFields() {
    #expect(
      TmuxListPanes.format
        == "#{pane_id}\u{1F}#{session_name}\u{1F}#{window_index}\u{1F}#{window_id}\u{1F}#{pane_index}\u{1F}#{pane_pid}\u{1F}#{pane_active}\u{1F}#{pane_current_command}"
    )
  }

  @Test("tmux 3.4 の実出力を複数 pane の値型へ変換する")
  func parsesTmux34Fixture() throws {
    let result = TmuxListPanes.parse(output: try fixture(named: "tmux-3.4-list-panes.txt"))
    let panes = result.panes

    #expect(result.failures.isEmpty)
    #expect(panes.count == 2)
    #expect(panes[0].paneID == PaneID(rawValue: "%0"))
    #expect(panes[0].sessionName == "pilot fixture [&]")
    #expect(panes[0].windowIndex == 0)
    #expect(panes[0].windowID == "@0")
    #expect(panes[0].paneIndex == 0)
    #expect(panes[0].panePID == 23_151)
    #expect(panes[0].isActive)
    #expect(panes[0].currentCommand == "sleep")

    #expect(panes[1].paneID == PaneID(rawValue: "%1"))
    #expect(panes[1].paneIndex == 1)
    #expect(panes[1].panePID == 23_162)
    #expect(!panes[1].isActive)
    #expect(panes[1].currentCommand == "zsh")
  }

  @Test("空白と一般的な記号を含む文字列をフィールド内に保持する")
  func preservesSpacesAndSymbols() throws {
    let separator = "\\037"
    let line = [
      "%7", "session alpha [&]", "2", "@4", "3", "4242", "1", "agent worker [&]",
    ].joined(separator: separator)

    let pane = try TmuxListPanes.parse(line: line)

    #expect(pane.sessionName == "session alpha [&]")
    #expect(pane.currentCommand == "agent worker [&]")
  }

  @Test("tmux 3.4 が正式名として返すバックスラッシュ符号化を保持する")
  func preservesOfficialSessionNameFromTmux34Fixture() throws {
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-hostile-session.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(result.panes.count == 1)
    #expect(result.panes.first?.sessionName == "pilot\\\\name \\\\037 literal\\ttab\\nline")
  }

  @Test("パース結果の正式 session 名は pilot-fixture3 の has-session -t で往復確認できる")
  func preservesRoundTrippableSessionNameFromTmux34Fixture() throws {
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-session-round-trip.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(
      result.panes.first?.sessionName
        == "pilot\\\\roundtrip \\\\037 literal\\ttab\\nline"
    )
  }

  @Test("非名前フィールドのバックスラッシュ・TAB・LFを復号せず保持する")
  func preservesRawCurrentCommandFromTmux34Fixture() throws {
    let output = try fixture(named: "tmux-3.4-list-panes-raw-current-command.txt")
    let line = String(output.dropLast())
    let pane = try TmuxListPanes.parse(line: line)

    #expect(output.last == "\n")
    #expect(pane.currentCommand == "cmd\\sl\nash\tz")
  }

  @Test("空の出力は pane が無いものとして空配列にする")
  func emptyOutputProducesNoPanes() {
    let result = TmuxListPanes.parse(output: "")

    #expect(result.panes.isEmpty)
    #expect(result.failures.isEmpty)
  }

  @Test("1行の異常があっても正常 pane と行番号・原文・エラーを両方返す")
  func preservesPartialSuccessAndLineFailure() {
    let validFirst = "%0\\037first\\0370\\037@0\\0370\\037123\\0371\\037zsh"
    let invalid = "%1\\037broken\\0370\\037@1\\0370\\037124\\0372\\037sleep"
    let validLast = "%2\\037last\\0371\\037@2\\0370\\037125\\0370\\037codex"

    let result = TmuxListPanes.parse(
      output: [validFirst, invalid, validLast].joined(separator: "\n"))

    #expect(result.panes.map(\.paneID) == [PaneID(rawValue: "%0"), PaneID(rawValue: "%2")])
    #expect(
      result.failures
        == [
          TmuxListPanesParseFailure(
            lineNumber: 2,
            line: invalid,
            error: .invalidPaneActive("2")
          )
        ]
    )
  }

  @Test("tmux の LF だけをレコード区切りとして U+2028 はフィールド内に保持する")
  func onlyLineFeedSeparatesRecords() {
    let sessionName = "before\u{2028}after"
    let line = "%0\\037\(sessionName)\\0370\\037@0\\0370\\037123\\0371\\037zsh"

    let result = TmuxListPanes.parse(output: line + "\n")

    #expect(result.failures.isEmpty)
    #expect(result.panes.first?.sessionName == sessionName)
  }

  @Test("フィールド数が8でなければ拒否する")
  func rejectsInvalidFieldCount() {
    #expect(throws: TmuxListPanesParseError.invalidFieldCount(actual: 2)) {
      try TmuxListPanes.parse(line: "%0\\037session")
    }
  }

  @Test("pane_active は0か1だけを受け入れる")
  func rejectsInvalidActiveValue() {
    #expect(throws: TmuxListPanesParseError.invalidPaneActive("2")) {
      try TmuxListPanes.parse(line: "%0\\037session\\0370\\037@0\\0370\\037123\\0372\\037zsh")
    }
  }

  private func fixture(named name: String) throws -> String {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    )
    return try String(contentsOf: fixtureURL, encoding: .utf8)
  }
}
