import SwiftUI

struct SessionCyclingCommands: Commands {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var shortcuts: ShortcutSettingsStore

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("前のセッション") { projects.selectedModel?.selectPreviousSession() }
        .keyboardShortcut(shortcuts.shortcut(for: .previousSession))
        .disabled(projects.selectedModel == nil)
      Button("次のセッション") { projects.selectedModel?.selectNextSession() }
        .keyboardShortcut(shortcuts.shortcut(for: .nextSession))
        .disabled(projects.selectedModel == nil)
      Button("次のセッション") { projects.selectedModel?.selectNextSession() }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled(projects.selectedModel == nil)
      Button("前のセッション") { projects.selectedModel?.selectPreviousSession() }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled(projects.selectedModel == nil)
    }
  }
}
