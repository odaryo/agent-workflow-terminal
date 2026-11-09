import SwiftUI

struct SessionCyclingCommands: Commands {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var shortcuts: ShortcutSettingsStore

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("前のセッション") { projects.selectAdjacentSession(forward: false) }
        .keyboardShortcut(shortcuts.shortcut(for: .previousSession))
        .disabled(projects.selectedModel == nil)
      Button("次のセッション") { projects.selectAdjacentSession(forward: true) }
        .keyboardShortcut(shortcuts.shortcut(for: .nextSession))
        .disabled(projects.selectedModel == nil)
      Button("次のセッション") { projects.selectAdjacentSession(forward: true) }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled(projects.selectedModel == nil)
      Button("前のセッション") { projects.selectAdjacentSession(forward: false) }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled(projects.selectedModel == nil)
    }
  }
}
