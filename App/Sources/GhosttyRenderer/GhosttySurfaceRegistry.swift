import AppKit

/// - Important: view を weak で保持する。強参照にすると `dismantleNSView` 後も view が生き残り、
///   surface を持ったまま tick の走査対象に残る。
@MainActor
final class GhosttySurfaceRegistry {
  static let shared = GhosttySurfaceRegistry()

  private struct WeakSurfaceView {
    weak var value: GhosttySurfaceView?
  }

  private var entries: [WeakSurfaceView] = []
  // Why not discard: NotificationCenter は token の解放時に observer を解除する。
  private var observers: [any NSObjectProtocol] = []

  private init() {
    // Why not view ごとに購読: 環境イベントは全 view に同じ意味を持ち、購読を1組へ集約すると
    // view の生存管理と通知の配布が同じ weak テーブルに乗る。
    observe(NSApplication.didBecomeActiveNotification, on: .default)
    observe(NSApplication.didChangeScreenParametersNotification, on: .default)
    observe(
      NSWorkspace.screensDidWakeNotification,
      on: NSWorkspace.shared.notificationCenter
    )
  }

  func register(_ view: GhosttySurfaceView) {
    compact()
    guard !entries.contains(where: { $0.value === view }) else { return }
    entries.append(WeakSurfaceView(value: view))
  }

  func unregister(_ view: GhosttySurfaceView) {
    entries.removeAll { $0.value == nil || $0.value === view }
  }

  func view(forSurfaceAddress address: UInt) -> GhosttySurfaceView? {
    liveViews().first { view in
      guard let surface = view.surface else { return false }
      return UInt(bitPattern: surface) == address
    }
  }

  func notifyEnvironmentMayHaveChanged() {
    for view in liveViews() { view.environmentMayHaveChanged() }
  }

  func pollProcessExit() {
    for view in liveViews() { view.pollProcessExit() }
  }

  private func liveViews() -> [GhosttySurfaceView] {
    compact()
    return entries.compactMap(\.value)
  }

  private func compact() {
    entries.removeAll { $0.value == nil }
  }

  private func observe(_ name: Notification.Name, on center: NotificationCenter) {
    observers.append(
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        // Why main queue へ移す: OperationQueue.main は main dispatch queue の context を保証しない。
        DispatchQueue.main.async {
          MainActor.assumeIsolated { Self.shared.notifyEnvironmentMayHaveChanged() }
        }
      }
    )
  }
}
