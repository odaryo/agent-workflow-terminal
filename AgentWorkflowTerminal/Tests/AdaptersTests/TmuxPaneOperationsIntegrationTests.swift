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

  @Test("方向指定は隣接 pane を選び、隣が無ければ選択を変えずに成功する")
  func selectNeighborMovesOnlyWhenNeighborExists() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("neighbor")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let left = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let right = try await operations.splitLeftRight(pane: left)
      try await operations.select(pane: left)

      try await operations.selectNeighbor(of: left, direction: .right)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == right)

      try await operations.selectNeighbor(of: right, direction: .left)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == left)

      // 上下に分割していないので、上下の隣接 pane は存在しない。
      try await operations.selectNeighbor(of: left, direction: .up)
      #expect(try await IsolatedTmuxServer.activePaneID(runner) == left)
    }
  }

  @Test("zoom と解除が window_zoomed_flag に反映され、繰り返しても状態が変わらない")
  func zoomStateIsIdempotent() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("zoom")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let original = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      _ = try await operations.splitLeftRight(pane: original)
      try await operations.select(pane: original)

      try await operations.setZoom(true, pane: original)
      try await expectZoom(runner, pane: original, isZoomed: true, isActive: true)
      try await operations.setZoom(true, pane: original)
      try await expectZoom(runner, pane: original, isZoomed: true, isActive: true)

      try await operations.setZoom(false, pane: original)
      try await expectZoom(runner, pane: original, isZoomed: false, isActive: true)
      try await operations.setZoom(false, pane: original)
      try await expectZoom(runner, pane: original, isZoomed: false, isActive: true)
    }
  }

  @Test("zoom 中の window で別 pane を zoom すると、その pane が zoom 対象になる")
  func zoomMovesToAnotherPaneWhileWindowIsZoomed() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("zoom-move")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let first = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let second = try await operations.splitLeftRight(pane: first)
      try await operations.setZoom(true, pane: first)

      try await operations.setZoom(true, pane: second)

      try await expectZoom(runner, pane: second, isZoomed: true, isActive: true)
    }
  }

  @Test("zoom 対象でない pane の解除は window の zoom を変えない")
  func unzoomDoesNothingForPaneThatIsNotZoomed() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("unzoom")) { runner in
      let operations = TmuxPaneOperations(runner: runner)
      let zoomed = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let other = try await operations.splitLeftRight(pane: zoomed)
      try await operations.setZoom(true, pane: zoomed)

      try await operations.setZoom(false, pane: other)

      try await expectZoom(runner, pane: zoomed, isZoomed: true, isActive: true)
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
        try await operations.setZoom(true, pane: missing)
      }
      await #expect(throws: TmuxPaneOperationError.paneNotFound(missing)) {
        try await operations.setZoom(false, pane: missing)
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
