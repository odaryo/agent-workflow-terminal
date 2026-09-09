/// SwiftUI の `.task` は view の消滅でキャンセルされるため、view より長く生きなければならない
/// 常駐ループをその中で直接回すと、window を閉じた時点で止まる (Issue #238)。本体をここへ預けると、
/// 呼び出し元 Task のキャンセルから切り離される。
///
/// - Important: 本体は unstructured な `Task` で起動する。`async let` や task group で起動すると
///   構造化された子になり、呼び出し元のキャンセルがそのまま伝播して同じ問題に戻る。
/// - Important: 起動した本体を止める手段は持たない。止められる必要が出たときに足すこと —
///   「アプリの生存期間だけ回るループ」以外へ広げると、寿命の所在がここと呼び出し元に分かれる。
@MainActor
public final class DetachedOnceTask {
  private var task: Task<Void, Never>?

  public init() {}

  /// 2 回目以降の呼び出しは何もしない。前回の本体が既に終了していても再入させない
  /// (「1 回だけ起動する」であって「同時に 1 本だけ」ではない)。
  ///
  /// - Returns: 本体を起動したかどうか。呼び出し側に使い道は無い。「起動しなかった」ことを
  ///   本体の副作用の**不在**で測ると、その観測は本体が走る順序に依存し、順序が崩れた日に
  ///   壊れた実装のまま緑になる。戻り値はそれを順序抜きで観測するためにある。
  @discardableResult
  public func start(_ body: @escaping @MainActor @Sendable () async -> Void) -> Bool {
    guard task == nil else { return false }
    task = Task { await body() }
    return true
  }
}
