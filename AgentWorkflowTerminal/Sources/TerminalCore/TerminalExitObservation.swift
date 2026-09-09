/// 端末タブが「プロセスの終わった端末を覆うべきか」を決める規則だけを持つ。
///
/// 世代 (`generation`) を突き合わせるのは、状態の通知が**非同期**に届くためである。世代を
/// 見ずに真偽値で持つと、作り直す前の surface から遅れて届いた `.exited` が、作り直した後の
/// 生きた端末を覆う。覆った上に置かれるのは「作り直す」操作なので、誤って覆うことは
/// 生きている端末を捨てさせることに直結する。
///
/// - Note: 表示の都合 (文言・色・レイアウト) はここに持ち込まない。ここにあるのは
///   「どの世代を覆うか」だけである。
public struct TerminalExitObservation: Equatable, Sendable {
  /// `nil` は「覆うべき世代が無い」。どの世代番号とも一致しない。
  private var exitedGeneration: Int?

  public init() {}

  public func isExited(generation: Int) -> Bool {
    exitedGeneration == generation
  }

  /// - Parameters:
  ///   - state: 観測した状態。
  ///   - generation: その状態を報せた surface の世代。
  ///
  /// `.exited` 以外を捨てずに**下ろす**のは、同じ世代が `.exited` から戻る経路が生きたときに
  /// 覆いが残り続けないようにするためである。残ると、生きている端末の上に「作り直す」操作が
  /// 出たままになる。下ろすのは同じ世代のときだけ — 古い世代の後片付け (`.stopped` など) が
  /// 遅れて届いても、今覆っている新しい世代の覆いを外さない。
  public mutating func observe(_ state: TerminalRendererState, generation: Int) {
    if state == .exited {
      exitedGeneration = generation
    } else if exitedGeneration == generation {
      exitedGeneration = nil
    }
  }
}
