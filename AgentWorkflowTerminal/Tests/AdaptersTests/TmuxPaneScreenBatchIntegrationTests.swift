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
