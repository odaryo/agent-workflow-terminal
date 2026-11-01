import TerminalCore

extension AppModel {
  func startNewTask() {
    guard projectRoot != nil else { return }
    selectProjectRoot()
  }
}
