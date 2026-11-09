import SwiftUI
import TerminalCore

/// `openWindow` は View の environment からしか取れないので、メニュー項目を View にする。
struct OverviewMenuItem: View {
  let navigator: AppNavigator
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // 端末 (`GhosttySurfaceView`) は `performKeyEquivalent` を持たないので、⌘ 付きの打鍵は
    // 端末より先にメニューへ届く (§5.4)。
    Button("Overview を表示") {
      navigator.toggleOverviewSidebar(openWindow: openWindow)
    }
    .keyboardShortcut("o", modifiers: [.command, .shift])
  }
}

struct OverviewView: View {
  @ObservedObject var projects: ProjectsModel
  @ObservedObject var navigator: AppNavigator
  let onSetAgentCommand: (RegisteredProject) -> Void
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      if let notice = navigator.overviewNotice {
        WarningBar(text: notice) { navigator.overviewNotice = nil }
        Divider()
      }
      HStack {
        Spacer()
        Button {
          chooseProjectDirectory(projects)
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Project を追加")
        .help("Project を追加")
      }
      .padding(8)
      if projects.availableModels.isEmpty {
        ContentUnavailableView(
          "表示できる Project がありません", systemImage: "rectangle.stack",
          description: Text("到達できる Project が登録されると、その Agent pane をここに並べます。"))
      } else {
        List {
          ForEach(projects.availableModels, id: \.project.commonDirectory) { model in
            OverviewProjectSection(
              model: model, store: model.paneObservations, mainPanes: model.mainPanes,
              isSelectedProject: projects.registry.selection == model.project.commonDirectory,
              selectProject: { projects.select(model.project.commonDirectory) },
              onSetAgentCommand: onSetAgentCommand,
              requestUnregister: { await projects.requestUnregister($0) },
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
      model, worktree: session.identity, session: session, pane: pane, in: projects)?.description
  }
}

private struct OverviewProjectSection: View {
  @ObservedObject var model: AppModel
  @ObservedObject var store: PaneObservationStore
  @ObservedObject var mainPanes: MainPaneCoordinator
  @AppStorage(OverviewProjectPreferences.collapsedProjectsKey) private var collapsedProjectsJSON =
    "[]"
  let isSelectedProject: Bool
  let selectProject: () -> Void
  let onSetAgentCommand: (RegisteredProject) -> Void
  let requestUnregister: (WorktreeIdentity) async -> Void
  let reveal: (TerminalSessionKey, PaneID?) -> Void

  var body: some View {
    let overview = makeAgentPaneOverview([input]).first
    let attentionCount = needsAttentionCount(overview)
    let showsAttentionCount = !isExpanded.wrappedValue && attentionCount > 0
    Section(isExpanded: isExpanded) {
      ForEach(overview?.projectRootSessions ?? [], id: \.session) { projectRoot in
        worktreeRows(projectRoot, title: nil)
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
          : model.project.displayName
      )
      .contextMenu {
        OverviewProjectMenu(
          model: model, selectProject: selectProject, onSetAgentCommand: onSetAgentCommand,
          requestUnregister: requestUnregister)
      }
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
  private func worktreeRows(_ worktree: OverviewWorktree, title: String?) -> some View {
    let isDisplayed = isSelectedProject && model.displayedSession == worktree.session
    if let title {
      Button {
        reveal(worktree.session, nil)
      } label: {
        HStack {
          Image(systemName: "chevron.right").opacity(isDisplayed ? 1 : 0)
          Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isDisplayed ? .primary : .secondary)
      }
      .buttonStyle(.plain)
      .help("このセッションを表示")
      .accessibilityLabel(isDisplayed ? "表示中 \(title)" : title)
      .contextMenu {
        OverviewSessionMenu(model: model, key: worktree.session, selectProject: selectProject)
      }
    }
    ForEach(worktree.rows, id: \.rowID) { row in
      let showsDisplayedMark = title == nil && isDisplayed && row == worktree.rows.first
      switch row {
      case .pane(let pane):
        OverviewPaneRow(
          pane: pane, store: store, showsDisplayedMark: showsDisplayedMark,
          sessionMenu: title == nil
            ? OverviewSessionMenu(model: model, key: worktree.session, selectProject: selectProject)
            : nil
        ) {
          reveal(worktree.session, pane.paneID)
        }
      case .noAgentPane, .notObserved:
        let shellTitle = worktree.session.index > 1 ? "シェル \(worktree.session.index)" : "シェル"
        let rowTitle = row == .notObserved ? "観測中…" : (title == nil ? shellTitle : "Agent pane なし")
        Button {
          reveal(worktree.session, nil)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right").opacity(showsDisplayedMark ? 1 : 0)
            Text(rowTitle)
          }
          .foregroundStyle(.secondary).padding(.leading, 12)
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDisplayedMark ? "表示中 \(rowTitle)" : rowTitle)
        .contextMenu {
          if title == nil {
            OverviewSessionMenu(model: model, key: worktree.session, selectProject: selectProject)
          }
        }
      }
    }
  }

  /// 初回配信待ちを除外すると、観測対象の Task が Overview から一時的に消える。
  private var input: OverviewProjectInput {
    OverviewProjectInput(
      project: model.project.commonDirectory,
      projectRootSessions: model.sessionKeys.filter { $0.identity == model.projectRoot?.identity }
        .compactMap { model.worktreeInput($0) },
      tasks: model.sessionKeys.filter { $0.identity != model.projectRoot?.identity }
        .compactMap { model.worktreeInput($0) })
  }
}

extension DetectedWorktree {
  /// セッションのディレクトリを識別できるよう、branch 名ではなくディレクトリ名を使う (設計書 §5.3)。
  var directoryName: String {
    URL(fileURLWithPath: worktreePath).lastPathComponent
  }
}

extension OverviewRow {
  /// worktree 内で一意。
  fileprivate var rowID: String {
    switch self {
    case .pane(let pane): pane.paneID.rawValue
    case .noAgentPane: "none"
    case .notObserved: "notObserved"
    }
  }
}
