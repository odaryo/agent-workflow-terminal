import SwiftUI

struct TabCyclingCommands: Commands {
  @ObservedObject var projects: ProjectsModel

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("前のセッション") { projects.selectedModel?.selectPreviousTab() }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(projects.selectedModel == nil)
      Button("次のセッション") { projects.selectedModel?.selectNextTab() }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(projects.selectedModel == nil)
      Button("次のセッション") { projects.selectedModel?.selectNextTab() }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled(projects.selectedModel == nil)
      Button("前のセッション") { projects.selectedModel?.selectPreviousTab() }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled(projects.selectedModel == nil)
    }
  }
}
