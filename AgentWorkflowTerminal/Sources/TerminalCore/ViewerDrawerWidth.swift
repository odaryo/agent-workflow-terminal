/// 単位は pt。`total - minimumTerminal < minimumDrawer` のときは Drawer の最小幅を優先し
/// (端末が `minimumTerminal` より狭くなる)、どの場合も `total` を超えない (§6.1)。
public enum ViewerDrawerWidth {
  public static func clamped(
    requested: Double, total: Double, minimumDrawer: Double, minimumTerminal: Double
  ) -> Double {
    min(min(max(requested, minimumDrawer), max(minimumDrawer, total - minimumTerminal)), total)
  }
}
