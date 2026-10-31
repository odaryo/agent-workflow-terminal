import TerminalCore

extension AppModel {
  func startNewTask() {
    guard projectRoot != nil else { return }
    if viewerDrawerLayout.presentation == .fullscreen {
      viewerDrawerLayout.setPresentation(.inline)
    }
    selectProjectRoot()
  }
}
