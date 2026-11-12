import SwiftUI

struct ProjectNameMaskCommands: Commands {
  @ObservedObject var projects: ProjectsModel

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Menu("Project 名を伏せる") {
        ForEach(projects.registry.projects, id: \.commonDirectory) { project in
          Toggle(
            project.presentedName,
            isOn: Binding(
              get: { projects.registry.project(project.commonDirectory)?.masksName ?? false },
              set: { projects.setMasksName($0, of: project.commonDirectory) }))
        }
      }
      .disabled(projects.registry.projects.isEmpty)
    }
  }
}
