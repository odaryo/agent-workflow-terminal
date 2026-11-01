import TerminalCore
import Testing

@Suite("Viewer Drawer の幅クランプ (設計書 §6.1)")
struct ViewerDrawerWidthTests {
  @Test(
    "範囲内はそのまま、最小幅と端末の最小幅による上限でクランプする",
    arguments: [
      (400.0, 1000.0, 240.0, 400.0),
      (100, 1000, 240, 240),
      (800, 1000, 240, 680),
      (240, 1000, 240, 240),
      (680, 1000, 240, 680),
      (800, 1400, 702, 800),
      (400, 1400, 702, 702),
      (1200, 1400, 702, 1080),
      (702, 1400, 702, 702),
      (1080, 1400, 702, 1080),
    ])
  func clampsWithinAvailableRange(
    requested: Double, total: Double, minimumDrawer: Double, expected: Double
  ) {
    #expect(
      ViewerDrawerWidth.clamped(
        requested: requested, total: total, minimumDrawer: minimumDrawer, minimumTerminal: 320)
        == expected)
  }

  @Test(
    "端末の最小幅を確保できないときは Drawer の最小幅を優先する",
    arguments: [
      (100.0, 500.0, 240.0),
      (400, 500, 240),
      (900, 500, 240),
      (400, 1000, 702),
      (800, 1000, 702),
      (1200, 1000, 702),
    ])
  func prioritizesMinimumDrawer(requested: Double, total: Double, minimumDrawer: Double) {
    #expect(
      ViewerDrawerWidth.clamped(
        requested: requested, total: total, minimumDrawer: minimumDrawer, minimumTerminal: 320)
        == minimumDrawer)
  }

  @Test(
    "全体幅が Drawer の最小幅より小さくても全体幅を超えない",
    arguments: [
      (100.0, 200.0, 240.0),
      (400, 200, 240),
      (400, 600, 702),
      (800, 600, 702),
      (400, 0, 240),
      (800, 0, 702),
    ])
  func neverExceedsTotal(requested: Double, total: Double, minimumDrawer: Double) {
    #expect(
      ViewerDrawerWidth.clamped(
        requested: requested, total: total, minimumDrawer: minimumDrawer, minimumTerminal: 320)
        == total)
  }
}
