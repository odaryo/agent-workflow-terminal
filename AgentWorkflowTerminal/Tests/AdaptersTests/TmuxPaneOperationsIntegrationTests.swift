import Adapters
import Foundation
import TerminalCore
import Testing

private let isTmuxIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "隔離 tmux server 上の pane 操作 (設計書 §4.1)",
  .enabled(if: isTmuxIntegrationEnabled)
)
struct TmuxPaneOperationsIntegrationTests {

  @Test("左右に並べる分割は上端をそろえ、左位置だけを分ける")
  func splitLeftRightPlacesPanesSideBySide() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("split-lr")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let original = try #require(await IsolatedTmuxServer.panes(runner).first)

      let created = try await operations.splitLeftRight(pane: original.id)

      let panes = try await IsolatedTmuxServer.panes(runner)
      #expect(panes.map(\.id).sorted { $0.rawValue < $1.rawValue } == [original.id, created])
      let createdRow = try #require(panes.first { $0.id == created })
      let originalRow = try #require(panes.first { $0.id == original.id })
      #expect(createdRow.top == originalRow.top)
      #expect(createdRow.left != originalRow.left)
    }
  }

  @Test("上下に並べる分割は左端をそろえ、上位置だけを分ける")
  func splitTopBottomStacksPanes() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("split-tb")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let original = try #require(await IsolatedTmuxServer.panes(runner).first)

      let created = try await operations.splitTopBottom(pane: original.id)

      let panes = try await IsolatedTmuxServer.panes(runner)
      #expect(panes.count == 2)
      let createdRow = try #require(panes.first { $0.id == created })
      let originalRow = try #require(panes.first { $0.id == original.id })
      #expect(createdRow.left == originalRow.left)
      #expect(createdRow.top != originalRow.top)
    }
  }

  @Test("close は pane を減らし、消えた pane への再実行は不在エラーになる")
  func closeRemovesPaneAndReportsMissingPaneOnRepeat() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("close")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let original = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let created = try await operations.splitLeftRight(pane: original)

      try await operations.close(pane: created)

      #expect(try await IsolatedTmuxServer.paneIDs(runner) == [original])
      await #expect(throws: TmuxPaneOperationError.paneNotFound(created)) {
        try await operations.close(pane: created)
      }
    }
  }

  @Test("選択は pane_active に反映され、同じ pane を選び直しても成功する")
  func selectIsIdempotent() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("select")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let original = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let created = try await operations.splitLeftRight(pane: original)

      try await operations.select(pane: original)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == original)

      try await operations.select(pane: original)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == original)

      try await operations.select(pane: created)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == created)
    }
  }

  @Test("方向指定は隣接 pane を選び、その方向に pane が無ければ選択が変わらない")
  func selectNeighborMovesToAdjacentPane() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("neighbor")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let left = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let right = try await operations.splitLeftRight(pane: left)
      try await operations.select(pane: left)

      try await operations.selectNeighbor(of: left, direction: .right)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == right)

      try await operations.selectNeighbor(of: right, direction: .left)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == left)

      // 左右にしか分割していないので、上下方向は回り込み先も自分自身になる。
      try await operations.selectNeighbor(of: left, direction: .up)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == left)
    }
  }

  @Test("端の pane から外向きに移動すると、window の反対側の端へ回り込む")
  func selectNeighborWrapsAtWindowEdge() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("wrap")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let top = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      // 2段だと「隣へ移動」と「反対側の端へ回り込み」が同じ結果になり、doc の主張を固定できない。
      let middle = try await operations.splitTopBottom(pane: top)
      let bottom = try await operations.splitTopBottom(pane: middle)
      try await operations.select(pane: top)

      try await operations.selectNeighbor(of: top, direction: .up)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == bottom)

      try await operations.selectNeighbor(of: bottom, direction: .down)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == top)
    }
  }

  @Test("zoom と解除が window_zoomed_flag に反映され、繰り返しても状態が変わらない")
  func zoomStateIsIdempotent() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("zoom")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let original = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      _ = try await operations.splitLeftRight(pane: original)
      try await operations.select(pane: original)

      try await operations.zoom(pane: original)
      try await expectZoom(runner, pane: original, isZoomed: true, isActive: true)
      try await operations.zoom(pane: original)
      try await expectZoom(runner, pane: original, isZoomed: true, isActive: true)

      try await operations.unzoom(pane: original)
      try await expectZoom(runner, pane: original, isZoomed: false, isActive: true)
      try await operations.unzoom(pane: original)
      try await expectZoom(runner, pane: original, isZoomed: false, isActive: true)
    }
  }

  @Test("zoom 中の window で別 pane を zoom すると、その pane が zoom 対象になる")
  func zoomMovesToAnotherPaneWhileWindowIsZoomed() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("zoom-move")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let first = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let second = try await operations.splitLeftRight(pane: first)
      try await operations.zoom(pane: first)

      try await operations.zoom(pane: second)

      try await expectZoom(runner, pane: second, isZoomed: true, isActive: true)
    }
  }

  @Test("別 pane が zoom 中のとき、その window の zoom は解除されない")
  func unzoomLeavesAnotherPanesZoomUntouched() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("unzoom")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let zoomed = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let other = try await operations.splitLeftRight(pane: zoomed)
      try await operations.zoom(pane: zoomed)

      try await operations.unzoom(pane: other)

      try await expectZoom(runner, pane: zoomed, isZoomed: true, isActive: true)
    }
  }

  @Test("pane が1つだけの window では、zoom は成功しても zoom されない")
  func zoomSucceedsWithoutZoomingSinglePaneWindow() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("zoom-single")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let only = try #require(await IsolatedTmuxServer.paneIDs(runner).first)

      try await operations.zoom(pane: only)

      try await expectZoom(runner, pane: only, isZoomed: false, isActive: true)
    }
  }

  @Test("最後の pane を閉じると server ごと消え、その後の close は不在エラーにならない")
  func closingTheLastPaneStopsTheServer() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("close-last")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let only = try #require(await IsolatedTmuxServer.paneIDs(runner).first)

      try await operations.close(pane: only)

      let raised = await #expect(throws: TmuxPaneOperationError.self) {
        try await operations.close(pane: only)
      }
      guard case .tmux(.commandFailed(let exitCode, _, let stderr)) = try #require(raised) else {
        Issue.record(
          "server 消失後の close が .tmux(.commandFailed) にならなかった: \(String(describing: raised))"
        )
        return
      }
      #expect(exitCode == 1)
      #expect(stderr.hasPrefix("no server running on "))
    }
  }

  @Test("存在しない pane を対象にした操作はすべて不在エラーになる")
  func missingPaneIsReportedForEveryOperation() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("missing")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let missing = try await missingPaneID(runner)

      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        _ = try await operations.splitLeftRight(pane: missing)
      }
      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        _ = try await operations.splitTopBottom(pane: missing)
      }
      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        try await operations.close(pane: missing)
      }
      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        try await operations.select(pane: missing)
      }
      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        try await operations.selectNeighbor(of: missing, direction: .down)
      }
      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        try await operations.zoom(pane: missing)
      }
      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        try await operations.unzoom(pane: missing)
      }
    }
  }

  private func expectZoom(
    _ runner: TmuxRunner,
    pane: PaneID,
    isZoomed: Bool,
    isActive: Bool
  ) async throws {
    let row = try #require(await IsolatedTmuxServer.panes(runner).first { $0.id == pane })
    #expect(row.isZoomed == isZoomed)
    #expect(row.isActive == isActive)
  }

  private func missingPaneID(_ runner: TmuxRunner) async throws -> PaneID {
    let used = try await IsolatedTmuxServer.paneIDs(runner)
      .compactMap { Int($0.rawValue.dropFirst()) }
    let next = (used.max() ?? 0) + 1_000
    return PaneID(rawValue: "%\(next)")
  }
}
