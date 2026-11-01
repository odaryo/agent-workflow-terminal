import Adapters
import AppKit
import GhosttyRenderer
import SwiftUI
import TerminalCore

@main
struct AgentWorkflowTerminalApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var projects: ProjectsModel
  @State private var minimumWindowWidth: CGFloat = 480

  init() {
    _projects = StateObject(wrappedValue: ProjectsModel(dependencies: AppDependencies.make()))
  }

  var body: some Scene {
    // `WindowGroup` にしない。複製された window は同じ `AppModel` を共有するため、開いている
    // タブごとに `GhosttySurfaceView` が二重に生成され、同一 tmux session へ 2 client が
    // attach する。tmux は最小の client に合わせるので、小さい方が既存の表示を縮める。main
    // main window は1枚で選択中の1 Project を表示すると設計書 §25 で確定しており (2026-10-08)、
    // 複製できる形にして壊れた状態で開けるようにはしない (Issue #238 / #372)。
    Window("Agent Workflow Terminal", id: "main") {
      ProjectsWindowContent(projects: projects)
        .modifier(HiddenWindowTitle())
        .background { ToolbarDisplayModeLock() }
        // 内側の frame は window に効かず (#430)、ここでも下限は 480 のまま (#477、未解決)。
        .frame(minWidth: minimumWindowWidth, minHeight: 320)
        .onPreferenceChange(ProjectMinimumWindowWidthKey.self) { [width = $minimumWindowWidth] in
          width.wrappedValue = $0
        }
    }
    .defaultSize(width: 900, height: 560)
    .commands {
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
    OverviewScene(projects: projects)
    Settings {
      NotificationSettingsView()
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
      WorktreeClosePanelHost(closing: model.closing)

      if let message = model.message ?? model.emptyStateMessage {
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
    .toolbar {
      if model.didCompleteInitialScan || model.projectRoot != nil || !model.worktrees.isEmpty {
        // CI の Xcode 16.4 (Swift 6.1、macOS 15 SDK) には macOS 26 の API が無く、#available だけ
        // ではコンパイルできない (#431)。Xcode 26 の Swift 6.2 以上でだけ使う。
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
          taskTabsToolbar.sharedBackgroundVisibility(.hidden)
        } else {
          taskTabsToolbar
        }
        if #available(macOS 26, *) {
          ToolbarSpacer(.flexible)
        }
        #else
        taskTabsToolbar
        #endif
        // primaryAction は macOS では leading 側に配置される。
        ToolbarItem(placement: .automatic) {
          ViewerDrawerToolbar(layout: $model.viewerDrawerLayout)
        }
      }
    }
    .modifier(ProjectWindowWidthPreference(model: model))
    .onAppear {
      var restored = ViewerArrangementPreferences.restoredLayout()
      if let content = model.viewerDrawerLayout.content { restored.open(content) }
      model.viewerDrawerLayout = restored
    }
    .onReceive(model.paneObservations.$terminalFocusRequest.dropFirst()) { _ in
      keyboardFocus.requestFocus()
    }
    .onChange(of: model.selectedTab) { _, _ in
      keyboardFocus.tabSelectionChanged()
    }
    .onChange(of: model.viewerDrawerLayout) { old, new in
      keyboardFocus.drawerLayoutChanged(from: old, to: new)
    }
  }

  private var taskTabsToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      HStack(spacing: 0) {
        ProjectTabStrip { tabs }
        NewTaskButton(isDisabled: model.projectRoot == nil, action: startNewTask)
        InactiveWorktreeMenu(
          worktrees: model.inactiveWorktrees,
          activate: { model.setActivation(.active, of: $0) }
        )
      }
    }
  }

  private var tabs: some View {
    // `LazyHStack` にしない。Active タブの代表状態は画面外でも観測し続ける必要があり
    // (Needs Attention を色で知らせる)、lazy にすると観測の有無がスクロール位置で
    // 変わる。対象が Active だけに絞られたので、観測の数はタブの数を超えない。
    HStack(spacing: 4) {
      ForEach(model.tabKeys, id: \.self) { key in
        if key.identity == model.projectRoot?.identity {
          ProjectRootTab(selected: model.selectedTab == key) {
            model.select(key)
          }
          .overlay {
            ToolbarContextMenu(items: [
              .action(title: NewTaskMenuItem.title, isEnabled: true, perform: startNewTask)
            ])
          }
          if key == model.tabLayout.tabs(in: key.identity).last, !model.tabbedWorktrees.isEmpty {
            Divider().frame(height: 22).padding(.horizontal, 2)
          }
        } else if let worktree = model.tabbedWorktrees.first(where: { $0.identity == key.identity })
        {
          WorktreeTab(
            worktree: worktree,
            selected: model.selectedTab == key,
            agentPaneStates: { model.agentPaneStates(of: worktree.identity) },
            select: { model.select(key) },
            setActivation: { model.setActivation($0, of: worktree.identity) },
            requestClose: { model.requestClose(of: worktree.identity) },
            startNewTask: startNewTask,
            isNewTaskDisabled: model.projectRoot == nil
          )
        }
      }
    }
    .padding(6)
  }
}

private struct ProjectRootTab: View {
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Project Root", systemImage: "shippingbox")
        .labelStyle(.titleAndIcon)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }
}

/// Inactive worktree を Active にする導線 (設計書 §3.2)。**状態は出さない** — 状態を出すには
/// pane を観測する必要があり、Inactive をタブから外した目的そのものが失われる (Issue #237)。
private struct InactiveWorktreeMenu: View {
  let worktrees: [TaskWorktree]
  let activate: (WorktreeIdentity) -> Void

  var body: some View {
    if !worktrees.isEmpty {
      // Viewer のメニューと同じ理由で、文字を出して AX の名前を「Inactive」にする。
      Menu {
        ForEach(worktrees, id: \.identity) { worktree in
          Button(title(of: worktree)) { activate(worktree.identity) }
            // 到達不能・観測失敗の Active 化は設計書 §3.2 が認めていない (attach 先を
            // 確かめられていない)。`AppModel.setActivation` も拒否するので、押せる見た目に
            // しない。
            .disabled(!worktree.detected.isReachable)
        }
      } label: {
        Label("Inactive", systemImage: "tray").labelStyle(.titleAndIcon)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }

  private func title(of worktree: TaskWorktree) -> String {
    let name =
      worktree.detected.branch
      ?? URL(fileURLWithPath: worktree.detected.worktreePath).lastPathComponent
    // 「観測失敗」を「到達不能」と出さない。到達できないと確かめられていないものを断定して
    // 見せないため (設計書 §12.3 と同じ理由、Issue #243)。
    switch worktree.detected.observation {
    case .reachable: return name
    case .unreachable: return "\(name) (到達不能)"
    case .observationFailed: return "\(name) (観測失敗)"
    }
  }
}

private struct WorktreeTab: View {
  let worktree: TaskWorktree
  let selected: Bool
  /// `AppModel.paneStates` を直に受けない。観測の可否を判定する経路を1本にし、タブ側と
  /// ドロワー側で食い違わないようにするため (Issue #237)。
  let agentPaneStates: () -> AsyncStream<[PaneAgentState]>?
  let select: () -> Void
  let setActivation: (WorktreeActivation) -> Void
  let requestClose: () -> Void
  let startNewTask: () -> Void
  let isNewTaskDisabled: Bool
  @State private var representativeState: WorktreeRepresentativeState?

  var body: some View {
    // 到達不能な worktree にはメニュー自体を付けない。設計書 §3.2 が Active 化を
    // 認めていない対象で、空のメニューを開かせないため。
    if worktree.detected.isReachable {
      tab.overlay {
        ToolbarContextMenu(items: [
          .action(
            title: NewTaskMenuItem.title, isEnabled: !isNewTaskDisabled
          ) { startNewTask() },
          .separator,
          .action(title: "Active にする", isEnabled: worktree.activation != .active) {
            setActivation(.active)
          },
          // Inactive 化は Close の選択肢1からだけ行う。§3.4 の拒否 (detached HEAD・作業途中) は
          // 選択肢1にも掛かり、直接 Inactive にする項目はその抜け道になる。
          .action(title: "Close…", isEnabled: true) { requestClose() },
        ])
      }
    } else {
      tab
    }
  }

  private var tab: some View {
    Button(action: select) {
      HStack(spacing: 6) {
        AgentStateIcon(presentation: statePresentation)
        Text(worktree.detected.tabName)
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
    // 記号の label (状態名、§5.3) を合成に任せず明示する。Overview の行では合成されなかった。
    .accessibilityLabel("\(worktree.detected.tabName) \(statePresentation.label)")
    // 到達不能な worktree は一覧から消さずに残す (設計書 §3.2)。消すと安定 ID が消失に見え、
    // 復帰したときにユーザーが意図した Active/Inactive が失われる。
    .disabled(!worktree.detected.isReachable)
    .opacity(worktree.detected.isReachable ? 1 : 0.4)
    // 観測が止まると購読は終わるので、到達できるようになったら購読し直す。
    .task(id: [worktree.identity.rawValue, "\(worktree.detected.isReachable)"]) {
      guard let paneStates = agentPaneStates() else { return }
      let states = WorktreeRepresentativeStateFeed().states(from: paneStates)
      for await state in states {
        representativeState = state
      }
    }
  }

  private var stateLabel: String {
    // 到達不能な worktree では pane を観測していない。`Idle` と出すと観測できていない状態を
    // 観測した状態に丸めることになる (設計書 §12.3 の `Unknown` と同じ理由)。
    // 「観測失敗」を「到達不能」と出さないのは、到達できないと確かめられていないものを
    // 断定して見せないためである (Issue #243)。
    switch worktree.detected.observation {
    case .unreachable: return "到達不能"
    case .observationFailed: return "観測失敗"
    case .reachable: break
    }
    guard let representativeState else { return "Idle" }
    return representativeState.state.displayLabel
  }

  private var statePresentation: AgentStatePresentation {
    guard worktree.detected.isReachable else { return .unobserved(stateLabel) }
    return AgentStatePresentation(
      state: representativeState?.state ?? .idle, category: representativeState?.category ?? .idle)
  }
}
