import SwiftUI
import TerminalCore

struct NewAgentSessionCommands: Commands {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var shortcuts: ShortcutSettingsStore

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Group {
        if let model = projects.selectedModel {
          NewAgentSessionMenuItem(projects: projects, model: model)
        } else {
          Button("新規セッションで Agent を起動") {}.disabled(true)
        }
      }
      .keyboardShortcut(shortcuts.shortcut(for: .newSessionWithAgent))
    }
  }
}

private struct NewAgentSessionMenuItem: View {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var model: AppModel

  var body: some View {
    Button("新規セッションで Agent を起動") {
      Task {
        guard let target else { return }
        await model.openNewSession(in: target.identity, agentCommand: target.agentCommand)
        model.paneObservations.requestTerminalFocus()
      }
    }
    .disabled(target == nil)
  }

  private var target: (identity: WorktreeIdentity, agentCommand: String)? {
    guard projects.selectedModel === model,
      let displayedSession = model.displayedSession,
      model.canOpenSession(in: displayedSession.identity),
      let command = projects.agentCommand(for: model.project.commonDirectory)
    else { return nil }
    return (displayedSession.identity, command)
  }
}
