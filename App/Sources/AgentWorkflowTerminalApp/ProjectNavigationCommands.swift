import SwiftUI

struct ProjectNavigationCommands: Commands {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var shortcuts: ShortcutSettingsStore

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("前のプロジェクト") { selectAdjacentProject(forward: false) }
        .keyboardShortcut(shortcuts.shortcut(for: .previousProject))
        .disabled(projects.selectedModel == nil)
      Button("次のプロジェクト") { selectAdjacentProject(forward: true) }
        .keyboardShortcut(shortcuts.shortcut(for: .nextProject))
        .disabled(projects.selectedModel == nil)
    }
  }

  private func selectAdjacentProject(forward: Bool) {
    guard
      let selection = projects.registry.adjacentSelection(
        forward: forward, selectable: projects.isSelectable)
    else { return }
    projects.select(selection)
    projects.selectedModel?.paneObservations.requestTerminalFocus()
  }
}
