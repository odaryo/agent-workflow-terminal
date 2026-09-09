import Adapters
import AppKit
import GhosttyRenderer
import SwiftUI
import TerminalCore

@main
struct AgentWorkflowTerminalApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel

  init() {
    _model = StateObject(wrappedValue: AppModel(dependencies: AppDependencies.make()))
  }

  var body: some Scene {
    WindowGroup("Agent Workflow Terminal") {
      ProjectView(model: model)
        .frame(minWidth: 480, minHeight: 320)
    }
    .defaultSize(width: 900, height: 560)
  }
}

private struct ProjectView: View {
  @ObservedObject var model: AppModel
  @StateObject private var keyboardFocus = TerminalKeyboardFocus()

  var body: some View {
    VStack(spacing: 0) {
      if let warning = model.warning {
        WarningBar(text: warning) { model.dismissWarning() }
        Divider()
      }
      if model.projectRoot != nil || !model.worktrees.isEmpty {
        HStack(spacing: 0) {
          ScrollView(.horizontal) {
            HStack(spacing: 4) {
              if let projectRoot = model.projectRoot {
                ProjectRootTab(selected: model.selectedIdentity == projectRoot.identity) {
                  model.selectProjectRoot()
                }
                if !model.worktrees.isEmpty {
                  Divider().frame(height: 22).padding(.horizontal, 2)
                }
              }
              ForEach(model.worktrees, id: \.identity) { worktree in
                WorktreeTab(
                  worktree: worktree,
                  selected: model.selectedIdentity == worktree.identity,
                  paneStates: model.paneStates,
                  select: { model.select(worktree) },
                  setActivation: { model.setActivation($0, of: worktree.identity) }
                )
              }
            }
            .padding(6)
          }
          .scrollIndicators(.hidden)
          ViewerDrawerToolbar(layout: $model.viewerDrawerLayout)
            .padding(.trailing, 6)
        }
        Divider()
      }

      if let message = model.message {
        ContentUnavailableView(
          "Agent Workflow Terminal", systemImage: "exclamationmark.triangle",
          description: Text(message))
      } else {
        ViewerDrawerView(
          layout: $model.viewerDrawerLayout,
          worktree: model.selectedWorktree,
          diffModels: model.diffModels,
          mainPanes: model.mainPanes,
          agentPaneStates: model.agentPaneStates(of:),
          keyboardFocus: keyboardFocus
        ) {
          TerminalTabs(model: model, keyboardFocus: keyboardFocus)
        }
      }
    }
    .task { await model.run() }
    .onChange(of: model.selectedIdentity) { _, _ in
      keyboardFocus.tabSelectionChanged(drawerLayout: model.viewerDrawerLayout)
    }
    .onChange(of: model.viewerDrawerLayout) { old, new in
      keyboardFocus.drawerLayoutChanged(from: old, to: new)
    }
  }
}

private struct WarningBar: View {
  let text: String
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle")
      Text(text).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 8)
      Button("閉じる", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.orange.opacity(0.15))
  }
}

private struct ViewerDrawerToolbar: View {
  @Binding var layout: ViewerDrawerLayout

  var body: some View {
    HStack(spacing: 4) {
      Menu("Viewer", systemImage: "sidebar.right") {
        ForEach(ViewerContent.allCases, id: \.self) { content in
          Button(content.toolbarTitle) { layout.openPrimary(content) }
        }
      }
      .menuStyle(.borderlessButton)

      if layout.isOpen {
        Menu("ペインを追加", systemImage: "rectangle.split.2x1") {
          ForEach(ViewerContent.allCases, id: \.self) { content in
            Button(content.toolbarTitle) { layout.openSecondary(content) }
          }
        }
        .menuStyle(.borderlessButton)

        Menu("表示方法", systemImage: "rectangle.on.rectangle") {
          Button("並べて表示") { layout.setPresentation(.inline) }
          Button("オーバーレイ") { layout.setPresentation(.overlay) }
          Button("フルスクリーン") { layout.setPresentation(.fullscreen) }
          Divider()
          Button("分割方向を切り替え") { layout.toggleSplitAxis() }
          Button("主と副を入れ替え") { layout.swapPanes() }
            .disabled(layout.secondary == nil)
        }
        .menuStyle(.borderlessButton)

        Button("Viewer を閉じる", systemImage: "xmark") { layout.closeAll() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
    }
  }
}

private extension ViewerContent {
  var toolbarTitle: String {
    switch self {
    case .code: "Code"
    case .diff: "Diff"
    case .evidence: "Evidence"
    }
  }
}

private struct TerminalTabs: View {
  @ObservedObject var model: AppModel
  @ObservedObject var keyboardFocus: TerminalKeyboardFocus

  var body: some View {
    ZStack {
      if let projectRoot = model.projectRoot,
        model.openedIdentities.contains(projectRoot.identity)
      {
        TerminalTabContent(
          worktree: projectRoot,
          sessions: model.sessions,
          focusRequest: focusRequest(for: projectRoot.identity)
        )
        .opacity(model.selectedIdentity == projectRoot.identity ? 1 : 0)
        .allowsHitTesting(model.selectedIdentity == projectRoot.identity)
      }
      ForEach(model.worktrees, id: \.identity) { worktree in
        if model.openedIdentities.contains(worktree.identity) {
          TerminalTabContent(
            worktree: worktree.detected,
            sessions: model.sessions,
            focusRequest: focusRequest(for: worktree.identity)
          )
          .opacity(model.selectedIdentity == worktree.identity ? 1 : 0)
          .allowsHitTesting(model.selectedIdentity == worktree.identity)
        }
      }
    }
  }

  private func focusRequest(for identity: WorktreeIdentity) -> TerminalFocusRequest? {
    keyboardFocus.focusRequest(isTabSelected: model.selectedIdentity == identity)
  }
}

private struct ProjectRootTab: View {
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Project Root", systemImage: "shippingbox")
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }
}

private struct WorktreeTab: View {
  let worktree: TaskWorktree
  let selected: Bool
  let paneStates: WorktreePaneStatesFeed?
  let select: () -> Void
  let setActivation: (WorktreeActivation) -> Void
  @State private var representativeState: WorktreeRepresentativeState?

  var body: some View {
    // 到達不能な worktree には `contextMenu` 自体を付けない。設計書 §3.2 が Active 化を
    // 認めていない対象で、空のメニューを開かせないため。
    if worktree.detected.isReachable {
      tab.contextMenu {
        Button("Active にする") { setActivation(.active) }
          .disabled(worktree.activation == .active)
        Button("Inactive にする") { setActivation(.inactive) }
          .disabled(worktree.activation == .inactive)
      }
    } else {
      tab
    }
  }

  private var tab: some View {
    Button(action: select) {
      HStack(spacing: 6) {
        Circle().fill(stateColor).frame(width: 8, height: 8)
        Text(
          worktree.detected.branch
            ?? URL(fileURLWithPath: worktree.detected.worktreePath).lastPathComponent
        )
        .foregroundStyle(worktree.activation == .active ? Color.primary : Color.secondary)
        Text(stateLabel).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
      .clipShape(.rect(cornerRadius: 6))
      .overlay {
        if worktree.activation == .active {
          RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
    // 到達不能な worktree は一覧から消さずに残す (設計書 §3.2)。消すと安定 ID が消失に見え、
    // 復帰したときにユーザーが意図した Active/Inactive が失われる。
    .disabled(!worktree.detected.isReachable)
    .opacity(worktree.detected.isReachable ? 1 : 0.4)
    .task(id: worktree.identity) {
      guard worktree.detected.isReachable, let paneStates else { return }
      let states = WorktreeRepresentativeStateFeed().states(from: paneStates(worktree.detected))
      for await state in states {
        representativeState = state
      }
    }
  }

  private var stateLabel: String {
    // 到達不能な worktree では pane を観測していない。`Idle` と出すと観測できていない状態を
    // 観測した状態に丸めることになる (設計書 §12.3 の `Unknown` と同じ理由)。
    guard worktree.detected.isReachable else { return "到達不能" }
    guard let representativeState else { return "Idle" }
    return representativeState.state.displayLabel
  }

  private var stateColor: Color {
    guard let representativeState else { return .secondary }
    return switch representativeState.category {
    case .needsAttention: .red
    case .readyForReview: .green
    case .working: .blue
    case .unknown: .orange
    case .idle: .secondary
    }
  }
}

private struct TerminalTabContent: View {
  let worktree: DetectedWorktree
  let sessions: TmuxSessionProvisioner?
  let focusRequest: TerminalFocusRequest?
  @State private var preparation = TerminalSessionPreparation.preparing

  var body: some View {
    Group {
      if sessions == nil {
        ContentUnavailableView("tmux を利用できません", systemImage: "terminal")
      } else {
        switch preparation {
        case .preparing:
          ProgressView("tmux session を用意しています")
        case .ready(let command):
          GhosttyTerminalView(
            command: command,
            workingDirectory: worktree.worktreePath,
            focusRequest: focusRequest
          )
        case .failed(let reason):
          ContentUnavailableView(
            "tmux session を用意できません", systemImage: "exclamationmark.triangle",
            description: Text(reason))
        }
      }
    }
    // タブごとに1回だけ走らせる。用意し直すと、その worktree の端末が動いている最中に
    // surface を作り替えることになる。
    .task(id: worktree.identity) {
      guard let sessions, case .preparing = preparation else { return }
      preparation =
        switch await sessions.attachCommand(
          for: worktree.identity, workingDirectory: worktree.worktreePath)
        {
        case .success(let command): .ready(command)
        case .failure(let error): .failed(error.terminalTabDescription)
        }
    }
  }
}

private enum TerminalSessionPreparation {
  case preparing
  /// surface へ渡す attach の argv。
  case ready([String])
  case failed(String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    setGhosttyApplicationFocus(true)
  }

  func applicationDidResignActive(_ notification: Notification) {
    setGhosttyApplicationFocus(false)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
