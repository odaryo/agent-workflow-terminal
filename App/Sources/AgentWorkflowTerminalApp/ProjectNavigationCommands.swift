import SwiftUI

struct ProjectNavigationCommands: Commands {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var shortcuts: ShortcutSettingsStore

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("前のプロジェクト") { selectAdjacentProject(forward: false) }
        .keyboardShortcut(shortcuts.shortcut(for: .previousProject))
        .disabled(projects.selectedModel == nil)
      Button("次のプロジェクト") { selectAdjacentProject(forward: true) }
        .keyboardShortcut(shortcuts.shortcut(for: .nextProject))
        .disabled(projects.selectedModel == nil)
      Button("プロジェクトを閉じる") { setSelectedProjectCollapsed(true) }
        .keyboardShortcut(shortcuts.shortcut(for: .collapseProject))
        .disabled(projects.selectedModel == nil)
      Button("プロジェクトを開く") { setSelectedProjectCollapsed(false) }
        .keyboardShortcut(shortcuts.shortcut(for: .expandProject))
        .disabled(projects.selectedModel == nil)
    }
  }

  private func setSelectedProjectCollapsed(_ collapsed: Bool) {
    guard let project = projects.selectedModel?.project.commonDirectory.rawValue else { return }
    let key = OverviewProjectPreferences.collapsedProjectsKey
    let currentValue = UserDefaults.standard.string(forKey: key) ?? "[]"
    guard
      let storedValue = OverviewProjectPreferences.storedValue(
        currentValue, settingCollapsed: collapsed, for: project),
      storedValue != currentValue
    else { return }
    UserDefaults.standard.set(storedValue, forKey: key)
  }

  private func selectAdjacentProject(forward: Bool) {
    guard
      let selection = projects.registry.adjacentSelection(
        forward: forward, selectable: projects.isSelectable)
    else { return }
    projects.select(selection)
    projects.selectedModel?.paneObservations.requestTerminalFocus()
  }
}
