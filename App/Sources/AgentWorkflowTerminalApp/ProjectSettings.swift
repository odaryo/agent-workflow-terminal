import AppKit
import SwiftUI

@MainActor
struct ProjectSettingsView: View {
  @ObservedObject var projects: ProjectsModel

  var body: some View {
    let unavailableProjects = projects.registry.projects.filter { project in
      if case .unavailable = projects.slots[project.commonDirectory] { return true }
      return false
    }

    Form {
      Section {
        if projects.registry.projects.isEmpty {
          Text("登録済みの Project はありません。")
        } else {
          ForEach(projects.registry.projects, id: \.commonDirectory) { project in
            Toggle(
              project.displayName,
              isOn: Binding(
                get: { projects.registry.project(project.commonDirectory)?.masksName ?? false },
                set: { projects.setMasksName($0, of: project.commonDirectory) }))
          }
        }
      } header: {
        Text("名前を伏せる Project")
      } footer: {
        Text("チェックした Project は Overview などで 1 文字目と伏字で表示します。")
      }

      Section("到達できない Project") {
        if unavailableProjects.isEmpty {
          Text("到達できない Project はありません。")
        } else {
          ForEach(unavailableProjects, id: \.commonDirectory) { project in
            if case .unavailable(let reason) = projects.slots[project.commonDirectory] {
              HStack {
                VStack(alignment: .leading) {
                  Text(project.displayName)
                  Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("登録を解除") {
                  Task {
                    await projects.requestUnregister(project.commonDirectory)
                    projects.navigator.openWindow?(id: "main")
                    NSApp.activate()
                  }
                }
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
  }
}
