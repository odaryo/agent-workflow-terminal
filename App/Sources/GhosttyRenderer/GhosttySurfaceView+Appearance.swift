import AppKit
import GhosttyKit

func ghosttyColorScheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
  // Why bestMatch: dark 系の派生 (vibrant など) も darkAqua に寄せるため。
  appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
}

extension GhosttySurfaceView {
  func observeWindowOcclusion() {
    if let occlusionObserver {
      NotificationCenter.default.removeObserver(occlusionObserver)
      self.occlusionObserver = nil
    }
    guard let window else { return }
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      // Why main queue へ移す: OperationQueue.main は main dispatch queue の context を保証しない。
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.applyOcclusion() }
      }
    }
  }

  func applyOcclusion() {
    guard let surface, let window else { return }
    // Why 可視なら true: 引数は occluded ではなく visible の向き
    // (App/vendor/ghostty/src/Surface.zig:3248)。
    ghostty_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
  }

  func applyColorScheme(_ scheme: ghostty_color_scheme_e? = nil) {
    guard let surface else { return }
    // Why NSApp から読む: view の appearance は上書きされうる
    // (App/vendor/ghostty/macos/Sources/App/macOS/AppDelegate.swift:296-310)。
    ghostty_surface_set_color_scheme(
      surface, scheme ?? ghosttyColorScheme(for: NSApp.effectiveAppearance))
  }
}
