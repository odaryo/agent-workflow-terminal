import SwiftUI

struct SessionCyclingCommands: Commands {
  @ObservedObject var projects: ProjectsModel

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("前のセッション") { projects.selectedModel?.selectPreviousSession() }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(projects.selectedModel == nil)
      Button("次のセッション") { projects.selectedModel?.selectNextSession() }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
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
