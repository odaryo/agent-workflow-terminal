import SwiftUI
import TerminalCore

struct OverviewSessionMenu: View {
  @ObservedObject var model: AppModel
  let key: TerminalSessionKey
  let selectProject: () -> Void

  var body: some View {
    Button("新規セッション") {
      selectProject()
      Task {
        await model.openNewSession(in: key.identity)
        model.paneObservations.requestTerminalFocus()
      }
    }
    .disabled(!model.canOpenSession(in: key.identity))
    Button("セッションを閉じる") {
      selectProject()
      model.requestCloseSession(key)
    }
    .disabled(!model.canCloseSession(key))
  }
}

struct OverviewProjectMenu: View {
  @ObservedObject var model: AppModel
  let selectProject: () -> Void
  let onSetAgentCommand: (RegisteredProject) -> Void
  let requestUnregister: (WorktreeIdentity) async -> Void

  var body: some View {
    Button("新規セッション (Project Root)") {
      selectProject()
      guard let projectRoot = model.projectRoot else { return }
      Task {
        await model.openNewSession(in: projectRoot.identity)
        model.paneObservations.requestTerminalFocus()
      }
    }
    .disabled(model.projectRoot.map { !model.canOpenSession(in: $0.identity) } ?? true)
    Menu("Inactive の worktree を Active にする") {
      ForEach(model.inactiveWorktrees, id: \.identity) { worktree in
        Button(title(of: worktree)) {
          model.setActivation(.active, of: worktree.identity)
        }
        .disabled(!worktree.detected.isReachable)
      }
    }
    .disabled(model.inactiveWorktrees.isEmpty)
    Button("Agent 起動コマンド…") {
      selectProject()
      onSetAgentCommand(model.project)
    }
    Button("登録を解除…") {
      selectProject()
      Task { await requestUnregister(model.project.commonDirectory) }
    }
  }

  private func title(of worktree: TaskWorktree) -> String {
    let name = worktree.detected.directoryName
    switch worktree.detected.observation {
    case .reachable: return name
    case .unreachable: return "\(name) (到達不能)"
    case .observationFailed: return "\(name) (観測失敗)"
    }
  }
}
