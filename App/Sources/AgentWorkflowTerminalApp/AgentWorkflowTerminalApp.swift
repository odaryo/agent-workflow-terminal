import Adapters
import AppKit
import GhosttyRenderer
import SwiftUI
import TerminalCore

@main
struct AgentWorkflowTerminalApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var projects: ProjectsModel

  init() {
    _projects = StateObject(wrappedValue: ProjectsModel(dependencies: AppDependencies.make()))
  }

  var body: some Scene {
    // `WindowGroup` にしない。複製された window は同じ `AppModel` を共有するため、開いている
    // セッションごとに `GhosttySurfaceView` が二重に生成され、同一 tmux session へ 2 client が
    // attach する。tmux は最小の client に合わせるので、小さい方が既存の表示を縮める。
    // main window は1枚で選択中の1 Project を表示する (設計書 §25)。
    Window("Agent Workflow Terminal", id: "main") {
      ProjectsWindowContent(projects: projects)
        .modifier(HiddenWindowTitle())
        .background { ToolbarDisplayModeLock() }
        // Drawer の下限は preference では root へ届かず、WindowExpansion で保持する (#477 計測)。
        .frame(minWidth: 480, minHeight: 320)
    }
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unifiedCompact)
    .defaultSize(width: 900, height: 560)
    .commands {
      ProjectNameMaskCommands(projects: projects)
      ProjectNavigationCommands(projects: projects, shortcuts: projects.shortcuts)
      SessionCyclingCommands(projects: projects, shortcuts: projects.shortcuts)
      NewAgentSessionCommands(projects: projects, shortcuts: projects.shortcuts)
      ViewerCommands(projects: projects, shortcuts: projects.shortcuts)
      CommandGroup(after: .toolbar) {
        OverviewMenuItem(navigator: projects.navigator, shortcuts: projects.shortcuts)
      }
      // `Window` だけで File メニューごと消えることは計測済みで、この行は多重防御。
      CommandGroup(replacing: .newItem) {}
      // File メニューが消えると ⌘W も巻き添えになる。このアプリは
      // `applicationShouldTerminateAfterLastWindowClosed` が `true` なので、⌘W は終了導線でも
      // ある。`.newItem` / `.printItem` へ置くと組み込みの Close が重複して現れたため
      // `.saveItem` に置く (Issue #238 の計測)。
      //
      // - Note: 計測で確かめたのはメニュー項目と ⌘W の生成までで、`performClose` が実際に
      //   window を閉じるところは未検証 (#316)。
      CommandGroup(replacing: .saveItem) {
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut("w")
      }
    }
    Settings {
      AppSettingsView(projects: projects)
    }
  }
}

private struct HiddenWindowTitle: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.toolbar(removing: .title)
    } else {
      content
    }
  }
}

struct ProjectView: View {
  @ObservedObject var model: AppModel
  let masksProjectName: Bool
  @StateObject var keyboardFocus = TerminalKeyboardFocus()

  var body: some View {
    VStack(spacing: 0) {
      if let warning = model.warning {
        WarningBar(text: warning) { model.dismissWarning() }
        Divider()
      }
      // 観測失敗を上と同じスロットへ載せない (`AppModel.scanFailureWarning`)。2本同時に出ても
      // 端末が潰れないのは、`WarningBar` がどちらも1行に丸めているためである。
      if let scanFailureWarning = model.scanFailureWarning {
        WarningBar(text: scanFailureWarning) { model.dismissScanFailureWarning() }
        Divider()
      }
      WorktreeClosePanelHost(closing: model.closing, masksProjectName: masksProjectName)
      TerminalSessionClosePanelHost(closing: model.sessionClosing) { model.confirmCloseSession() }

      if let message = model.message ?? model.emptyStateMessage {
        ContentUnavailableView(
          "Agent Workflow Terminal", systemImage: "exclamationmark.triangle",
          description: Text(message))
      } else {
        ViewerDrawerView(
          layout: $model.viewerDrawerLayout,
          worktree: model.selectedWorktree,
          selectedSession: model.displayedSession,
          diffModels: model.diffModels,
          mainPanes: model.mainPanes,
          agentPaneStates: { identity in
            let key =
              model.displayedSession.flatMap { $0.identity == identity ? $0 : nil }
              ?? .primary(identity)
            return model.agentPaneStates(of: key)
          },
          keyboardFocus: keyboardFocus,
          terminal: { TerminalSessionsView(model: model, keyboardFocus: keyboardFocus) }
        )
      }
    }
    .toolbar {
      if model.didCompleteInitialScan || model.projectRoot != nil || !model.worktrees.isEmpty {
        // CI の Xcode 16.4 (Swift 6.1、macOS 15 SDK) には macOS 26 の API が無く、#available だけ
        // ではコンパイルできない。Xcode 26 の Swift 6.2 以上でだけ使う。
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
          ToolbarSpacer(.flexible)
        }
        #endif
        // primaryAction は macOS では leading 側に配置される。
        ToolbarItem(placement: .automatic) {
          ViewerDrawerToolbar(layout: $model.viewerDrawerLayout)
        }
      }
    }
    .onAppear {
      var restored = ViewerArrangementPreferences.restoredLayout()
      if let content = model.viewerDrawerLayout.content { restored.open(content) }
      model.viewerDrawerLayout = restored
    }
    // Project の切替前に出た要求は、新しい view では初回値になる。dropFirst すると失われる。
    .onReceive(model.paneObservations.$terminalFocusRequest) { _ in
      keyboardFocus.requestFocus()
    }
    .onChange(of: model.displayedSession) { _, _ in
      keyboardFocus.displayedSessionChanged()
    }
    .onChange(of: model.viewerDrawerLayout) { old, new in
      keyboardFocus.drawerLayoutChanged(from: old, to: new)
    }
  }
}
