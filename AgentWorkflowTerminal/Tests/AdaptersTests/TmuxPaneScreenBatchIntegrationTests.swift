import Foundation
import TerminalCore
import Testing

@testable import Adapters

private let isBatchIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

/// バッチ捕捉は「1プロセスで複数 pane を撃つ」ので、失敗の切れ方も出力の並びも実 tmux でしか
/// 確かめられない (Issue #239 R2)。
@Suite("capture-pane バッチの実 tmux 挙動", .enabled(if: isBatchIntegrationEnabled))
struct TmuxPaneScreenBatchIntegrationTests {
  /// 実時計に依存させないため、TTL は1テストが終わるより十分長く取る。
  private let timeToLive = Duration.seconds(30)

  @Test("バッチで取った画面は単独 capture-pane とバイト一致する")
  func batchedScreensMatchSingleCaptures() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("screen-batch")
    ) { runner in
      for text in ["alpha", "bravo"] {
        _ = try await runner.run(
          arguments: [
            "split-window", "-d", "-t", "=awt-operations:0.0",
            "printf '\(text)\\n\(text)-2\\n'; sleep 300",
          ])
      }
      let panes = try await IsolatedTmuxServer.paneIDs(runner)
      try await waitForScreen(containing: "bravo", runner: runner)

      var singles: [PaneID: String] = [:]
      for pane in panes {
        singles[pane] = try await runner.run(
          arguments: ["capture-pane", "-e", "-p", "-t", pane.rawValue]
        ).stdout
      }

      let batcher = TmuxPaneScreenBatcher(runner: runner, timeToLive: timeToLive)
      var batched: [PaneID: String] = [:]
      for pane in panes {
        let result = try await batcher.screen(of: pane)
        guard case .captured(let text) = result.screen else {
          Issue.record("pane \(pane.rawValue) の画面を取れなかった: \(result.screen)")
          continue
        }
        batched[pane] = text
      }

      #expect(panes.count == 3)
      #expect(batched == singles)
    }
  }

  @Test("消えた pane はその1件だけ paneNotFound になり、残りは同じ周期で取れる")
  func missingPaneDoesNotStopTheRest() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("screen-batch-missing")
    ) { runner in
      _ = try await runner.run(arguments: ["split-window", "-d", "-t", "=awt-operations:0.0"])
      let panes = try await IsolatedTmuxServer.paneIDs(runner)
      let ghost = PaneID(rawValue: "%9999")
      let batcher = TmuxPaneScreenBatcher(runner: runner, timeToLive: timeToLive)

      _ = try await batcher.screen(of: panes[0])
      let ghostResult = try await batcher.screen(of: ghost)
      // ghost の登録が外れた後の新しいバッチ。ここで残りの pane が取れることが要点。
      let secondResult = try await batcher.screen(of: panes[1])
      let firstResult = try await batcher.screen(of: panes[0])

      #expect(ghostResult.screen == .paneNotFound)
      #expect(isCaptured(secondResult.screen))
      #expect(isCaptured(firstResult.screen))
    }
  }

  /// バッチの失敗検出が exit code ではなくマーカーの中身に依存している理由そのもの。
  /// この事実を忘れて exit code へ戻すと、capture と marker の間で消えた pane が
  /// `.paneNotFound` にならず、そのグループの後続 pane がまとめて取れなくなる (F4)。
  @Test("display-message は消えた pane でも exit 0 で空の pane_id を返す")
  func displayMessageDoesNotFailForMissingPane() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("screen-batch-marker")
    ) { runner in
      let marker = TmuxPaneScreenBatch.markerTemplate(nonce: "AWTPROBE")
      let panes = try await IsolatedTmuxServer.paneIDs(runner)

      let missing = try await runner.run(
        arguments: ["display-message", "-t", "%9999", "-p", marker])
      let live = try await runner.run(
        arguments: ["display-message", "-t", panes[0].rawValue, "-p", marker])

      // exit 0 で返るので、exit code では live と区別できない。
      #expect(missing.exitCode == 0)
      #expect(missing.stderr.isEmpty)
      #expect(missing.stdout.hasPrefix("AWTPROBE "))
      // 区別できるのはマーカーの中身だけ。消えた pane では pane ID が空になる。
      #expect(
        TmuxPaneScreenBatch.parse(
          stdout: missing.stdout, nonce: "AWTPROBE", expected: [PaneID(rawValue: "%9999")]
        ).entries.isEmpty)
      #expect(
        TmuxPaneScreenBatch.parse(
          stdout: live.stdout, nonce: "AWTPROBE", expected: [panes[0]]
        ).entries.count == 1)
    }
  }

  /// title は画面と同じマーカーから来るので、鮮度は画面と一致する (F1)。
  ///
  /// - Important: **title に backslash を入れない。** tmux 3.7c は `#{pane_title}` を展開する
  ///   時点で backslash を二重化する (3.4 はしない)。実測: 実 title `t\itle` に対し
  ///   置換を挟まない生の `#{pane_title}` が 3.4 = `t\itle` / 3.7c = `t\\itle`。format 側の
  ///   `s/\\/\\\\/` はどちらの版でも n→2n なので 3.7c だけ合計 4n になり、1 段しか半減しない
  ///   `decodeRawField` は backslash が倍のまま返す。**これは `list-panes` 経由でも同じで、
  ///   この変更とは無関係に main に存在する** (素の main の `TmuxListPanes.parse` へ実機 3.7c
  ///   の `list-panes` 出力を食わせて再現済み)。ここで測りたいのは title の鮮度なので、
  ///   版差のある文字を避ける。`$` は両版とも往復する (3.4 は `\$` を生成し、3.7c は素通し)。
  @Test("バッチのマーカーから実 tmux の pane title を取り出す")
  func readsLivePaneTitleFromMarker() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("screen-batch-title")
    ) { runner in
      let panes = try await IsolatedTmuxServer.paneIDs(runner)
      // tmux は実物のまま、TTL の満了だけを手で進める。
      let clock = ManualTimeSource()
      let batcher = TmuxPaneScreenBatcher(
        runner: runner, timeToLive: timeToLive, timeSource: clock)

      _ = try await runner.run(
        arguments: ["select-pane", "-t", panes[0].rawValue, "-T", "first title $x"])
      let first = try await batcher.screen(of: panes[0])
      _ = try await runner.run(
        arguments: ["select-pane", "-t", panes[0].rawValue, "-T", "second title"])
      clock.advance(by: timeToLive)
      let second = try await batcher.screen(of: panes[0])

      #expect(first.snapshot.titles[panes[0]] == "first title $x")
      #expect(second.snapshot.titles[panes[0]] == "second title")
    }
  }

  private func isCaptured(_ screen: TmuxPaneScreen) -> Bool {
    guard case .captured = screen else { return false }
    return true
  }

  /// pane で起動したコマンドの出力が画面へ乗るまで待つ。`split-window` の復帰は exec の完了を
  /// 意味しないため、待たずに読むと空画面と比較してしまう。
  private func waitForScreen(
    containing needle: String, runner: TmuxRunner
  ) async throws {
    for _ in 0..<200 {
      for pane in try await IsolatedTmuxServer.paneIDs(runner) {
        let screen = try await runner.run(
          arguments: ["capture-pane", "-p", "-t", pane.rawValue])
        if screen.stdout.contains(needle) { return }
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("pane の出力が現れなかった: \(needle)")
  }
}
