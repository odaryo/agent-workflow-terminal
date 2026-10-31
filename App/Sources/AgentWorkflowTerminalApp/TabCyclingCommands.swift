import SwiftUI

struct TabCyclingCommands: Commands {
  @ObservedObject var projects: ProjectsModel

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("次のタブ") { projects.selectedModel?.selectNextTab() }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled(projects.selectedModel == nil)
      Button("前のタブ") { projects.selectedModel?.selectPreviousTab() }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled(projects.selectedModel == nil)
    }
  }
}
