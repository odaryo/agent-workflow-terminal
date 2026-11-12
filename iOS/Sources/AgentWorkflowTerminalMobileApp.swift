import SwiftUI

@main
@MainActor
struct AgentWorkflowTerminalMobileApp: App {
  @State private var model = MobileClientModel()

  var body: some Scene {
    WindowGroup {
      MobileClientView(model: model)
    }
  }
}
