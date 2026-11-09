import SwiftUI

struct ViewerCommands: Commands {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var shortcuts: ShortcutSettingsStore

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Code Viewer") { projects.selectedModel?.viewerDrawerLayout.toggle(.code) }
        .keyboardShortcut(shortcuts.shortcut(for: .toggleCodeViewer))
        .disabled(projects.selectedModel == nil)
      Button("Diff Viewer") { projects.selectedModel?.viewerDrawerLayout.toggle(.diff) }
        .keyboardShortcut(shortcuts.shortcut(for: .toggleDiffViewer))
        .disabled(projects.selectedModel == nil)
      Button("Evidence Viewer") { projects.selectedModel?.viewerDrawerLayout.toggle(.evidence) }
        .keyboardShortcut(shortcuts.shortcut(for: .toggleEvidenceViewer))
        .disabled(projects.selectedModel == nil)
    }
  }
}
