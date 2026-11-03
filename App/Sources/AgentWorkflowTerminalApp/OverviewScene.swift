import AppKit
import SwiftUI
import TerminalCore

/// 全 Agent pane の Overview (設計書 §13)。
///
/// `WindowGroup` にしない。複製できると同じ一覧が2枚になるだけで、§13 の「通常のウィンドウ1枚」
/// に反する。位置とサイズは `Window` の id (`overview`) を名前に SwiftUI が `NSWindow Frame
/// overview` として保存する (メイン window の `NSWindow Frame main` と同じ機構、実測)。
struct OverviewScene: Scene {
  @ObservedObject var projects: ProjectsModel

  var body: some Scene {
    Window("Overview", id: "overview") {
      OverviewWindowContent(projects: projects)
        .frame(minWidth: 420, minHeight: 240)
    }
    .defaultSize(width: 640, height: 480)
    .commands {
      TabCyclingCommands(projects: projects)
      CommandGroup(after: .toolbar) {
        OverviewMenuItem(navigator: projects.navigator)
      }
    }
  }
}

/// `openWindow` は View の environment からしか取れないので、メニュー項目を View にする。
private struct OverviewMenuItem: View {
  let navigator: AppNavigator
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // 端末 (`GhosttySurfaceView`) は `performKeyEquivalent` を持たないので、⌘ 付きの打鍵は
    // 端末より先にメニューへ届く (§5.4)。
    Button("Overview を表示") {
      switch OverviewPresentation.current() {
      case .window: openWindow(id: "overview")
      case .sidebar: navigator.toggleOverviewSidebar(openWindow: openWindow)
      }
    }
    .keyboardShortcut("o", modifiers: [.command, .shift])
  }
}

/// サイドバー表示では Overview のウィンドウを出さない (§13)。
///
/// Why not `defaultLaunchBehavior(.suppressed)`: macOS 15 の API で、deployment target の 14 では
/// 使えず、scene の修飾子なので条件付きにもできない。起動時に SwiftUI がこの scene を開くことが
/// ある (main d3f897a でユーザーが観測。state restoration は無効にしているので原因は未計測) ため、
/// 開いてしまったウィンドウを表示形態を見て閉じる。設定でサイドバーへ切り替えた時にも同じ経路で閉じる。
private struct OverviewWindowContent: View {
  @ObservedObject var projects: ProjectsModel
  @AppStorage(OverviewPresentation.key) private var presentation = OverviewPresentation.default
    .rawValue
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    Group {
      if OverviewPresentation(storedValue: presentation) == .window {
        OverviewView(projects: projects, navigator: projects.navigator)
      }
    }
    .onChange(of: presentation, initial: true) {
      if OverviewPresentation(storedValue: presentation) == .sidebar {
        dismissWindow(id: "overview")
      }
    }
  }
}

struct OverviewView: View {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var navigator: AppNavigator
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      if let notice = navigator.overviewNotice {
        WarningBar(text: notice) { navigator.overviewNotice = nil }
        Divider()
      }
      if projects.availableModels.isEmpty {
        ContentUnavailableView(
          "表示できる Project がありません", systemImage: "rectangle.stack",
          description: Text("到達できる Project が登録されると、その Agent pane をここに並べます。"))
      } else {
        List {
          ForEach(projects.availableModels, id: \.project.commonDirectory) { model in
            OverviewProjectSection(
              model: model, store: model.paneObservations, mainPanes: model.mainPanes,
              reveal: { session, pane in
                Task { await reveal(model, session: session, pane: pane) }
              })
          }
        }
        .listStyle(.sidebar)
      }
    }
    .onAppear { navigator.openWindow = openWindow }
  }

  /// §13 の行の選択。
  private func reveal(_ model: AppModel, session: TerminalSessionKey, pane: PaneID?) async {
    navigator.overviewNotice = nil
    navigator.overviewNotice = await navigator.reveal(
      model, worktree: session.identity, session: session, pane: pane, in: projects)
  }
}

private struct OverviewProjectSection: View {
  @ObservedObject var model: AppModel
  @ObservedObject var store: PaneObservationStore
  @ObservedObject var mainPanes: MainPaneCoordinator
  @AppStorage(OverviewProjectPreferences.collapsedProjectsKey) private var collapsedProjectsJSON =
    "[]"
  let reveal: (TerminalSessionKey, PaneID?) -> Void

  var body: some View {
    let overview = makeAgentPaneOverview([input]).first
    let attentionCount = needsAttentionCount(overview)
    let showsAttentionCount = !isExpanded.wrappedValue && attentionCount > 0
    Section(isExpanded: isExpanded) {
      ForEach(overview?.projectRootSessions ?? [], id: \.session) { projectRoot in
        worktreeRows(projectRoot, title: model.sessionTitle(projectRoot.session))
      }
      ForEach(overview?.tasks ?? [], id: \.session) { task in
        worktreeRows(task, title: model.sessionTitle(task.session))
      }
    } header: {
      HStack {
        Text(model.project.displayName)
        Spacer()
        if showsAttentionCount {
          Text("要対応 \(attentionCount)")
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        showsAttentionCount
          ? "\(model.project.displayName)、要対応 \(attentionCount) 件"
          : model.project.displayName)
    }
  }

  private var isExpanded: Binding<Bool> {
    Binding {
      !OverviewProjectPreferences.collapsedProjects(storedValue: collapsedProjectsJSON)
        .contains(model.project.commonDirectory.rawValue)
    } set: { expanded in
      var collapsedProjects = OverviewProjectPreferences.collapsedProjects(
        storedValue: collapsedProjectsJSON)
      let project = model.project.commonDirectory.rawValue
      if expanded {
        collapsedProjects.remove(project)
      } else {
        collapsedProjects.insert(project)
      }
      if let storedValue = OverviewProjectPreferences.storedValue(for: collapsedProjects) {
        collapsedProjectsJSON = storedValue
      }
    }
  }

  private func needsAttentionCount(_ overview: OverviewProject?) -> Int {
    let worktrees = (overview?.projectRootSessions ?? []) + (overview?.tasks ?? [])
    return worktrees.flatMap(\.rows).filter { row in
      if case .pane(let pane) = row {
        return pane.display.category == .needsAttention
      }
      return false
    }.count
  }

  @ViewBuilder
  private func worktreeRows(_ worktree: OverviewWorktree, title: String) -> some View {
    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    ForEach(worktree.rows, id: \.rowID) { row in
      switch row {
      case .pane(let pane):
        OverviewPaneRow(pane: pane, store: store) { reveal(worktree.session, pane.paneID) }
      case .noAgentPane:
        Button {
          reveal(worktree.session, nil)
        } label: {
          Text("Agent pane なし").foregroundStyle(.secondary).padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// Q6 (Issue #189): 観測していない worktree (Inactive・到達不能・観測失敗) は出さない。
  /// 状態を持たない行を並べると、観測できていないものを「Agent pane なし」と断定して見せる。
  private var input: OverviewProjectInput {
    OverviewProjectInput(
      project: model.project.commonDirectory,
      projectRootSessions: model.tabKeys.filter { $0.identity == model.projectRoot?.identity }
        .compactMap { model.worktreeInput($0) },
      tasks: model.tabKeys.filter { $0.identity != model.projectRoot?.identity }
        .compactMap { model.worktreeInput($0) })
  }
}

extension DetectedWorktree {
  /// Task Tab と Overview の見出しで同じ名前を出す。食い違うと、Overview の行がどのタブか
  /// 見分けられない。
  var tabName: String {
    branch ?? URL(fileURLWithPath: worktreePath).lastPathComponent
  }
}

extension OverviewRow {
  /// worktree 内で一意。
  fileprivate var rowID: String {
    switch self {
    case .pane(let pane): pane.paneID.rawValue
    case .noAgentPane: "none"
    }
  }
}
