import TerminalCore

extension ObservationChannel {
  /// 再選択では、旧 subscription の解除と新 adapter の登録が別々の Task で届き、順序は決まらない。
  /// 片方だけ届いた時点の `adapterID(for:)` は `nil` か旧 adapter を返すので、両方が届くまで待つ。
  /// 期待する adapter ID では待たない — 誤った adapter が選ばれたとき、上限まで待たずにその値で
  /// 失敗させるため。
  ///
  /// 上限に達しても失敗にはせず戻る。成否は呼び出し側の `#expect` が記録し、テストはハングしない。
  /// 上限は実時間 (`ContinuousClock`) で測る。`FeedTestClock` の `now` は固定値で進まない。
  func waitForReselection(
    of paneID: PaneID, cancellations: Int, timeout: Duration = .seconds(5)
  ) async {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while cancellationCount < cancellations || adapterID(for: paneID) == nil,
      ContinuousClock().now < deadline
    {
      await Task.yield()
    }
  }
}
