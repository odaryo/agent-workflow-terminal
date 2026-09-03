import AppKit
import GhosttyRenderer
import SwiftUI

@main
struct AgentWorkflowTerminalApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  private let command = [
    ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  ]

  var body: some Scene {
    WindowGroup("Agent Workflow Terminal") {
      GhosttyTerminalView(command: command)
        .frame(minWidth: 480, minHeight: 320)
    }
    .defaultSize(width: 900, height: 560)
  }
}

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
}
