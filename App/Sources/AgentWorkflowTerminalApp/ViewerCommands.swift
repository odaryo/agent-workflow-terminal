import SwiftUI

struct ViewerCommands: Commands {
  @ObservedObject var projects: ProjectsModel

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Code Viewer") { projects.selectedModel?.viewerDrawerLayout.toggle(.code) }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(projects.selectedModel == nil)
      Button("Diff Viewer") { projects.selectedModel?.viewerDrawerLayout.toggle(.diff) }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(projects.selectedModel == nil)
      Button("Evidence Viewer") { projects.selectedModel?.viewerDrawerLayout.toggle(.evidence) }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(projects.selectedModel == nil)
    }
  }
}
