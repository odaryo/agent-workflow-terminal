import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("capture-pane バッチの argv と復号")
struct TmuxPaneScreenBatchTests {
  private let panes = [PaneID(rawValue: "%1"), PaneID(rawValue: "%2")]
  /// tmux 3.4 の非 control-mode 出力は format の Unit Separator を `\037` にする (実測)。
  private let separator = #"\037"#

  @Test("capture の直後に、pane ID と title を運ぶマーカーを置いた列を組み立てる")
  func buildsSequencedArguments() {
    let marker = "AWTNONCE " + TmuxListPanes.agentPaneStatusFormat
    #expect(
      TmuxPaneScreenBatch.arguments(panes: panes, nonce: "AWTNONCE")
        == [
          "capture-pane", "-e", "-p", "-t", "%1",
          ";", "display-message", "-t", "%1", "-p", marker,
          ";", "capture-pane", "-e", "-p", "-t", "%2",
          ";", "display-message", "-t", "%2", "-p", marker,
        ])
  }

  /// `display-message -p` はテンプレートの**リテラル部**を strftime 展開する (tmux 3.4 実測:
  /// `MARKER-%0-end` → `MARKER--end`)。マーカーが黙って欠けると、直後の pane の画面が
  /// 前の pane の画面として配られる。
  @Test("マーカーはバッチごとに変わり、リテラル % を含まない")
  func makesPercentFreeUniqueNonce() {
    let first = TmuxPaneScreenBatch.makeNonce()
    let second = TmuxPaneScreenBatch.makeNonce()
    #expect(first != second)
    #expect(!TmuxPaneScreenBatch.markerTemplate(nonce: first).contains("%"))
    #expect(first != second)
    #expect(!second.contains("%"))
  }

  @Test("マーカーで区切った画面を単独 capture と同じ文字列へ戻し、title も取り出す")
  func decodesScreensAndTitlesBetweenMarkers() {
    let stdout =
      "a\nb\nAWTNONCE %1\(separator)first title\n"
      + "\n\n\nAWTNONCE %2\(separator)second title\n"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.entries.map(\.pane) == panes)
    #expect(parsed.entries.map(\.screen) == ["a\nb\n", "\n\n\n"])
    #expect(parsed.entries.map(\.title) == ["first title", "second title"])
    #expect(parsed.stopReason == .completed)
  }

  /// 列の途中が失敗すると以降のコマンドは実行されず、失敗前の stdout だけが残る
  /// (tmux 3.4 実測)。
  @Test("列が途中で切れた stdout はマーカーが閉じた pane までを返す")
  func stopsAtTruncatedOutput() {
    let stdout = "a\nAWTNONCE %1\(separator)t\nhalf"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.entries.count == 1)
    #expect(parsed.entries[0].pane == panes[0])
    #expect(parsed.entries[0].screen == "a\n")
    #expect(parsed.stopReason == .truncated)
  }

  @Test("引数と違う並びのマーカーが出たらそこで解釈を止め、消失として扱う")
  func stopsAtUnexpectedMarkerOrder() {
    let stdout = "a\nAWTNONCE %9\(separator)t\nb\nAWTNONCE %2\(separator)t\n"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.entries.isEmpty)
    #expect(parsed.stopReason == .paneIdentityMismatch)
  }

  /// tmux 3.4 の `display-message` は存在しない pane を指しても exit 0 で空の `#{pane_id}` を
  /// 返す (実測)。exit code では検出できないので、マーカーの中身で判定する。
  @Test("pane ID が空のマーカーは完成とみなさず、消失として扱う")
  func stopsAtEmptyPaneIDMarker() {
    let stdout = "a\nAWTNONCE \(separator)\nb\nAWTNONCE %2\(separator)t\n"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.entries.isEmpty)
    #expect(parsed.stopReason == .paneIdentityMismatch)
  }

  /// pane ID は正しいのに区切りが失われた形。pane は生きているので消失にはしない。
  @Test("pane ID 以外が壊れたマーカーは消失ではなく復号失敗として報告する")
  func reportsMalformedMarkerWithoutClaimingDisappearance() {
    let stdout = "a\nAWTNONCE %1\nb\nAWTNONCE %2\(separator)t\n"
    let parsed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: "AWTNONCE", expected: panes)

    #expect(parsed.entries.isEmpty)
    #expect(parsed.stopReason == .malformedMarker)
  }

  /// 出力段の escape は `TmuxListPanes` の既存規則で復号する。
  @Test("title の backslash と $ の escape を復号する")
  func decodesEscapedTitle() {
    let stdout = #"x\#nAWTNONCE %1\#(separator)back\\slash \$dollar\#n"#
    let parsed = TmuxPaneScreenBatch.parse(
      stdout: stdout, nonce: "AWTNONCE", expected: [panes[0]])

    #expect(parsed.entries.map(\.title) == [#"back\slash $dollar"#])
  }
}
