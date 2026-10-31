import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

struct ViewerDrawerMetricsTests {
  struct WidthCase: Sendable {
    let total: CGFloat
    let requested: CGFloat
    let drawer: CGFloat
  }

  @Test(
    "並べて表示の幅制約",
    arguments: [
      WidthCase(total: 1000.0, requested: 420.0, drawer: 420.0),
      WidthCase(total: 1000.0, requested: 100.0, drawer: 240.0),
      WidthCase(total: 1000.0, requested: 900.0, drawer: 680.0),
      WidthCase(total: 500.0, requested: 420.0, drawer: 240.0),
      WidthCase(total: 200.0, requested: 420.0, drawer: 240.0),
    ])
  func inlineWidths(values: WidthCase) {
    let metrics = ViewerDrawerMetrics(
      presentation: .inline, totalWidth: values.total, requestedWidth: values.requested
    )
    #expect(metrics.drawerWidth == values.drawer)
    #expect(metrics.terminalWidth == max(values.total - values.drawer, 0))
    #expect(metrics.drawerOffsetX == max(values.total - values.drawer, 0))
  }

  @Test(
    "オーバーレイの幅制約",
    arguments: [
      WidthCase(total: 1000.0, requested: 420.0, drawer: 420.0),
      WidthCase(total: 1000.0, requested: 100.0, drawer: 240.0),
      WidthCase(total: 1000.0, requested: 900.0, drawer: 680.0),
      WidthCase(total: 500.0, requested: 420.0, drawer: 240.0),
      WidthCase(total: 200.0, requested: 420.0, drawer: 200.0),
      WidthCase(total: 0.0, requested: 420.0, drawer: 0.0),
    ])
  func overlayWidths(values: WidthCase) {
    let metrics = ViewerDrawerMetrics(
      presentation: .overlay, totalWidth: values.total, requestedWidth: values.requested
    )
    #expect(metrics.drawerWidth == values.drawer)
    #expect(metrics.terminalWidth == values.total)
    #expect(metrics.drawerOffsetX == values.total - values.drawer)
  }

  @Test("フルスクリーンは要求幅によらず全幅", arguments: [100.0, 420.0, 1200.0])
  func fullscreenWidth(requested: Double) {
    let metrics = ViewerDrawerMetrics(
      presentation: .fullscreen, totalWidth: 1000, requestedWidth: CGFloat(requested)
    )
    #expect(metrics.drawerWidth == 1000)
    #expect(metrics.drawerOffsetX == 0)
    #expect(!metrics.isTerminalVisible)
  }
}
