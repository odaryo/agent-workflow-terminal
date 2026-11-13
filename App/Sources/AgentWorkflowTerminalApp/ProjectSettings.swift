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
          ForEach(
            Array(projects.registry.projects.enumerated()), id: \.element.commonDirectory
          ) { index, project in
            HStack {
              Toggle(
                project.displayName,
                isOn: Binding(
                  get: { projects.registry.project(project.commonDirectory)?.masksName ?? false },
                  set: { projects.setMasksName($0, of: project.commonDirectory) }))
              Button {
                projects.moveProject(project.commonDirectory, to: index - 1)
              } label: {
                Image(systemName: "chevron.up")
              }
              .accessibilityLabel("「\(project.displayName)」を上へ移動")
              .help("「\(project.displayName)」を上へ移動")
              .disabled(index == 0)

              Button {
                projects.moveProject(project.commonDirectory, to: index + 1)
              } label: {
                Image(systemName: "chevron.down")
              }
              .accessibilityLabel("「\(project.displayName)」を下へ移動")
              .help("「\(project.displayName)」を下へ移動")
              .disabled(index == projects.registry.projects.count - 1)
            }
          }
        }
      } header: {
        Text("Project")
      } footer: {
        Text(
          "チェックした Project は Overview などで 1 文字目と伏字で表示します。"
            + "上下のボタンで並べ替えた順を Overview と Project の移動に使います。")
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
