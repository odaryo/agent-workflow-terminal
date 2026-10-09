import AppKit
import GhosttyRenderer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    setGhosttyApplicationFocus(true)
  }

  func applicationDidResignActive(_ notification: Notification) {
    setGhosttyApplicationFocus(false)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  /// window の state restoration を使わない (Issue #189)。使うと、Overview を開いたまま終了した
  /// 次の起動で **Overview だけが復元され、メイン window が開かない** (SIGTERM で実測)。Project の
  /// 読み込みはメイン window が始めるので、その Overview は空のまま残る。Overview の
  /// `NSWindow.isRestorable = false` では止まらなかった (SwiftUI の scene 復元は別経路、実測)。
  /// 位置とサイズは frame の autosave (`NSWindow Frame <id>`) が覚えるので失われない。
  ///
  /// - Note: SwiftUI の `restorationBehavior(.disabled)` は macOS 15 からで、対象の 14 では使えない。
  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
    false
  }
}
