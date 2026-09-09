import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("capture-pane バッチの argv と復号")
struct TmuxPaneScreenBatchTests {
  private let panes = [PaneID(rawValue: "%1"), PaneID(rawValue: "%2")]

  @Test("capture の直後にマーカーを置いた列を組み立てる")
  func buildsSequencedArguments() {
    #expect(
      TmuxPaneScreenBatch.arguments(panes: panes, nonce: "AWTNONCE")
        == [
          "capture-pane", "-e", "-p", "-t", "%1",
          ";", "display-message", "-t", "%1", "-p", "AWTNONCE #{pane_id}",
          ";", "capture-pane", "-e", "-p", "-t", "%2",
          ";", "display-message", "-t", "%2", "-p", "AWTNONCE #{pane_id}",
        ])
  }

  /// `display-message -p` はテンプレートを strftime 展開する (tmux 3.4 実測:
  /// `MARKER-%0-end` → `MARKER--end`)。マーカーが黙って欠けると、直後の pane の画面が
  /// 前の pane の画面として配られる。
  @Test("マーカーはバッチごとに変わり、リテラル % を含まない")
  func makesPercentFreeUniqueNonce() {
    let first = TmuxPaneScreenBatch.makeNonce()
    let second = TmuxPaneScreenBatch.makeNonce()
    #expect(first != second)
    #expect(!first.contains("%"))
    #expect(!second.contains("%"))
  }

  @Test("マーカーで区切った画面を単独 capture と同じ文字列へ戻す")
  func decodesScreensBetweenMarkers() {
    let stdout = "a\nb\nAWTNONCE %1\n\n\n\nAWTNONCE %2\n"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.map(\.pane) == panes)
    #expect(parsed.map(\.screen) == ["a\nb\n", "\n\n\n"])
  }

  /// 列の途中が失敗すると以降のコマンドは実行されず、失敗前の stdout だけが残る
  /// (tmux 3.4 実測)。
  @Test("列が途中で切れた stdout はマーカーが閉じた pane までを返す")
  func stopsAtTruncatedOutput() {
    let stdout = "a\nAWTNONCE %1\nhalf"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.count == 1)
    #expect(parsed[0].pane == panes[0])
    #expect(parsed[0].screen == "a\n")
  }

  @Test("引数と違う並びのマーカーが出たらそこで解釈を止める")
  func stopsAtUnexpectedMarkerOrder() {
    let stdout = "a\nAWTNONCE %9\nb\nAWTNONCE %2\n"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.isEmpty)
  }
}
