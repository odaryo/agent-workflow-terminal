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
      OverviewView(projects: projects)
        .frame(minWidth: 420, minHeight: 240)

    }
    .defaultSize(width: 640, height: 480)
    .commands {
      CommandGroup(after: .toolbar) {
        OverviewMenuItem()
      }
    }
  }
}

/// `openWindow` は View の environment からしか取れないので、メニュー項目を View にする。
private struct OverviewMenuItem: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // 端末 (`GhosttySurfaceView`) は `performKeyEquivalent` を持たないので、⌘ 付きの打鍵は
    // 端末より先にメニューへ届く (§5.4)。
    Button("Overview を表示") { openWindow(id: "overview") }
      .keyboardShortcut("o", modifiers: [.command, .shift])
  }
}

private struct OverviewView: View {
  @ObservedObject var projects: ProjectsModel
  @Environment(\.openWindow) private var openWindow
  @State private var navigationError: String?

  var body: some View {
    VStack(spacing: 0) {
      if let navigationError {
        WarningBar(text: navigationError) { self.navigationError = nil }
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
              reveal: { worktree, pane in
                Task { await reveal(model, worktree: worktree, pane: pane) }
              })
          }
        }
      }
    }
  }

  /// §13 の行の選択。Project → タブ → tmux の window と pane → メイン window の端末、の順に移す。
  private func reveal(_ model: AppModel, worktree: WorktreeIdentity, pane: PaneID?) async {
    navigationError = nil
    projects.select(model.project.commonDirectory)
    if model.projectRoot?.identity == worktree {
      model.selectProjectRoot()
    } else if let task = model.worktrees.first(where: { $0.identity == worktree }) {
      model.select(task)
    }
    if let pane, let error = await model.paneObservations.reveal(pane) {
      navigationError = "pane \(pane.rawValue) へ移動できません: \(error)"
    }
    openWindow(id: "main")
    NSApp.activate()
    model.paneObservations.requestTerminalFocus()
  }
}

private struct OverviewProjectSection: View {
  @ObservedObject var model: AppModel
  @ObservedObject var store: PaneObservationStore
  @ObservedObject var mainPanes: MainPaneCoordinator
  let reveal: (WorktreeIdentity, PaneID?) -> Void

  var body: some View {
    let overview = makeAgentPaneOverview([input]).first
    Section(model.project.displayName) {
      if let projectRoot = overview?.projectRoot {
        worktreeRows(projectRoot, title: "Project Root")
      }
      ForEach(overview?.tasks ?? [], id: \.worktree) { task in
        worktreeRows(task, title: title(of: task.worktree))
      }
    }
  }

  @ViewBuilder
  private func worktreeRows(_ worktree: OverviewWorktree, title: String) -> some View {
    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    ForEach(worktree.rows, id: \.rowID) { row in
      switch row {
      case .pane(let pane):
        OverviewPaneRow(pane: pane, store: store) { reveal(worktree.worktree, pane.paneID) }
      case .noAgentPane:
        Button {
          reveal(worktree.worktree, nil)
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
      projectRoot: model.projectRoot.flatMap { worktreeInput($0.identity) },
      tasks: model.tabbedWorktrees.compactMap { worktreeInput($0.identity) })
  }

  private func worktreeInput(_ identity: WorktreeIdentity) -> OverviewWorktreeInput? {
    guard model.inventory.observesPaneStates(of: identity), let observed = store.observed[identity]
    else { return nil }
    return OverviewWorktreeInput(
      worktree: identity, paneStates: observed.displayStates, details: observed.details,
      mainPane: mainPane(of: identity, observed: observed))
  }

  private func mainPane(
    of identity: WorktreeIdentity, observed: PaneObservationStore.Observed
  ) -> PaneID? {
    guard let registration = mainPanes.registry.registration(for: identity),
      observed.processIDs[registration.pane] == registration.processID
    else { return nil }
    return registration.pane
  }

  private func title(of identity: WorktreeIdentity) -> String {
    model.worktrees.first { $0.identity == identity }?.detected.tabName ?? identity.rawValue
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
