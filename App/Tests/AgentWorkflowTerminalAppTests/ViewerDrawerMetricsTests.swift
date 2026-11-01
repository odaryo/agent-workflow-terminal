import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

struct ViewerDrawerMetricsTests {
  struct WidthCase: Sendable {
    let total: CGFloat
    let requested: CGFloat
    let drawer: CGFloat
    var minimum: CGFloat = 240
  }

  @Test(
    "並べて表示の幅制約",
    arguments: [
      WidthCase(total: 1000.0, requested: 420.0, drawer: 420.0),
      WidthCase(total: 1000.0, requested: 100.0, drawer: 240.0),
      WidthCase(total: 1000.0, requested: 900.0, drawer: 680.0),
      WidthCase(total: 500.0, requested: 420.0, drawer: 240.0),
      WidthCase(total: 200.0, requested: 420.0, drawer: 200.0),
      WidthCase(total: 0.0, requested: 420.0, drawer: 0.0),
      WidthCase(total: -100.0, requested: 420.0, drawer: 0.0),
      WidthCase(total: 1000.0, requested: 420.0, drawer: 702.0, minimum: 702),
      WidthCase(total: 1200.0, requested: 900.0, drawer: 880.0, minimum: 702),
      WidthCase(total: 1000.0, requested: 240.0, drawer: 421.0, minimum: 421),
    ])
  func inlineWidths(values: WidthCase) {
    let metrics = ViewerDrawerMetrics(
      isOpen: true, minimumDrawerWidth: values.minimum,
      totalWidth: values.total, requestedWidth: values.requested
    )
    #expect(metrics.drawerWidth == values.drawer)
    #expect(metrics.terminalWidth == max(values.total - values.drawer, 0))
    #expect(metrics.drawerOffsetX == max(values.total - values.drawer, 0))
    #expect(metrics.isDrawerVisible)
  }

  struct MinimumCase: Sendable {
    let content: ViewerContent
    let arrangement: ViewerContentArrangement?
    let width: CGFloat
  }

  @Test(
    "中身と並びに必要な最小幅",
    arguments: [
      MinimumCase(content: .code, arrangement: .sideBySide, width: 421),
      MinimumCase(content: .code, arrangement: .stacked, width: 240),
      MinimumCase(content: .diff, arrangement: .sideBySide, width: 702),
      MinimumCase(content: .diff, arrangement: .stacked, width: 240),
      MinimumCase(content: .evidence, arrangement: nil, width: 240),
    ])
  func minimumWidths(values: MinimumCase) {
    #expect(
      ViewerDrawerMetrics.minimumDrawerWidth(for: values.content, arrangement: values.arrangement)
        == values.width)
  }

  @Test("閉じた Drawer は端末の幅を縮めない", arguments: [CGFloat(200), CGFloat(1000)])
  func closedWidths(total: CGFloat) {
    let metrics = ViewerDrawerMetrics(
      isOpen: false, minimumDrawerWidth: 702, totalWidth: total, requestedWidth: 900)
    #expect(metrics.terminalWidth == total)
    #expect(metrics.drawerWidth == min(420, total))
    #expect(metrics.drawerOffsetX == total - metrics.drawerWidth)
    #expect(!metrics.isDrawerVisible)
  }

  @Test("window の最小幅は端末と選んだ並びとつまみを含む")
  func windowMinimumWidth() {
    var layout = ViewerDrawerLayout()
    #expect(ViewerDrawerMetrics.minimumWindowWidth(for: layout) == 480)
    layout.open(.code)
    #expect(ViewerDrawerMetrics.minimumWindowWidth(for: layout) == 749)
    layout.setArrangement(.stacked, for: .code)
    #expect(ViewerDrawerMetrics.minimumWindowWidth(for: layout) == 568)
    layout.open(.diff)
    layout.setArrangement(.sideBySide, for: .diff)
    #expect(ViewerDrawerMetrics.minimumWindowWidth(for: layout) == 1030)
    layout.close()
    #expect(ViewerDrawerMetrics.minimumWindowWidth(for: layout) == 480)
  }
}
