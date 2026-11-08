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

  /// SwiftUI の `restorationBehavior(.disabled)` は macOS 15 からで、対象の 14 では使えない。
  /// 位置とサイズは frame の autosave (`NSWindow Frame <id>`) が覚えるので失われない。
  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
    false
  }
}
