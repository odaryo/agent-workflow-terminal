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
