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
    let panes = try TmuxListPanes.parse(output: fixture(named: "tmux-3.4-list-panes.txt"))

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

  @Test("空の出力は pane が無いものとして空配列にする")
  func emptyOutputProducesNoPanes() throws {
    #expect(try TmuxListPanes.parse(output: "").isEmpty)
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
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
    return try String(contentsOf: fixtureURL, encoding: .utf8)
  }
}
