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
  public func start(_ body: @escaping @MainActor @Sendable () async -> Void) {
    guard task == nil else { return }
    task = Task { await body() }
  }
}
