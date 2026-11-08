import AppKit
import SwiftUI
import TerminalCore

/// メイン window の中身。window は1枚のまま (`Window(id: "main")`、Issue #238) で、選択中の1 Project
/// だけを表示し、ツールバーのメニューで切り替える (Issue #372)。
struct ProjectsWindowContent: View {
  @ObservedObject var projects: ProjectsModel
  @Environment(\.openWindow) private var openWindow
  @AppStorage(OverviewSidebarPreferences.isOpenKey) private var isSidebarOpen =
    OverviewSidebarPreferences.defaultIsOpen
  @AppStorage(OverviewSidebarPreferences.widthKey) private var sidebarWidth =
    OverviewSidebarPreferences.defaultWidth
  @State private var pendingAgentCommand: RegisteredProject?

  private var sidebarOccupiedWidth: CGFloat {
    OverviewSidebarPreferences.occupiedWidth(isVisible: isSidebarOpen, width: sidebarWidth)
  }

  // Why not `.id(Project)` の内側: サイドバーを `ProjectView` の `.id` の内側や前後の分岐に置くと、
  // Project を切り替えるたびに作り直されてスクロール位置を失う。`.id` の外側で、`if` は HStack の
  // 先頭に固定し、開閉で右側の VStack (= 端末) の位置が変わって作り直されないようにする。
  //
  // サイドバーの開閉と幅の変更は、端末の領域を変えるので tmux の window の大きさを変える (§13)。
  var body: some View {
    HStack(spacing: 0) {
      if isSidebarOpen {
        sidebar
      }
      mainColumn
    }
    .modifier(OverviewToolbarBand())
    .background {
      if let model = projects.selectedModel {
        ProjectWindowExpansion(model: model, extraWidth: sidebarOccupiedWidth)
      } else {
        WindowExpansion(size: NSSize(width: 480 + sidebarOccupiedWidth, height: 320))
      }
    }
    .background { MainWindowCapture(navigator: projects.navigator) }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        ProjectMenu(projects: projects)
      }
    }
    .confirmationDialog(
      projects.pendingUnregister?.title ?? "",
      isPresented: Binding(
        get: { projects.pendingUnregister != nil },
        set: { if !$0 { projects.dismissUnregister() } }),
      titleVisibility: .visible,
      presenting: projects.pendingUnregister
    ) { review in
      Button("キャンセル", role: .cancel) {}
      Button("登録だけ解除") { projects.unregister(review.project.commonDirectory) }
      Button("session とデータも削除して解除", role: .destructive) {
        Task { await projects.unregisterAndDelete(review) }
      }
    } message: { review in
      Text(review.message)
    }
    .sheet(
      isPresented: Binding(
        get: { pendingAgentCommand != nil },
        set: { if !$0 { pendingAgentCommand = nil } })
    ) {
      if let project = pendingAgentCommand {
        ProjectAgentCommandSheet(project: project, projects: projects)
      }
    }
    .task { projects.start() }
    .onAppear { projects.navigator.openWindow = openWindow }
  }

  private var mainColumn: some View {
    VStack(spacing: 0) {
      if let warning = projects.warning {
        WarningBar(text: warning) { projects.dismissWarning() }
        Divider()
      }
      content
    }
  }

  private var sidebar: some View {
    HStack(spacing: 0) {
      OverviewView(projects: projects, navigator: projects.navigator) { pendingAgentCommand = $0 }
        .frame(width: CGFloat(OverviewSidebarPreferences.clamped(sidebarWidth)))
      DrawerResizeHandle(
        width: CGFloat(OverviewSidebarPreferences.clamped(sidebarWidth)),
        growsRightward: true,
        accessibilityLabel: "Overview の幅",
        onWidthChange: { sidebarWidth = OverviewSidebarPreferences.clamped(Double($0)) },
        onDragEnd: { sidebarWidth = OverviewSidebarPreferences.clamped(Double($0)) }
      )
      .frame(width: CGFloat(OverviewSidebarPreferences.handleWidth))
    }
  }

  @ViewBuilder private var content: some View {
    if !projects.didLoad {
      ProgressView("登録済みの Project を読み込んでいます")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let model = projects.selectedModel {
      // 選択中の Project の view だけを置く。`.id` で Project ごとに別の view にするので、
      // 切り替えると前の Project の端末は `dismantleNSView` で破棄され、tmux client が detach する
      // (session は残る)。タブのように opacity で重ねると前の Project の client が attach した
      // まま残り、戻ったときに同じ session へ2つ目の client が attach する。
      ProjectView(model: model)
        .id(model.project.commonDirectory)
    } else if projects.registry.projects.isEmpty {
      ContentUnavailableView {
        Label("Project が登録されていません", systemImage: "folder.badge.plus")
      } description: {
        Text("Git repository のフォルダを選んで登録してください。")
      } actions: {
        Button("Project を追加…") { chooseProjectDirectory(projects) }
      }
    } else {
      ContentUnavailableView(
        "選択できる Project がありません", systemImage: "exclamationmark.triangle",
        description: Text("登録済みの Project にはどれも到達できません。ツールバーのメニューから理由を確認してください。"))
    }
  }
}

private struct OverviewToolbarBand: ViewModifier {
  func body(content: Content) -> some View {
    // 項目の sharedBackgroundVisibility だけでは、sidebar の List 背景や境界線が
    // titlebar へ延びるのを防げない。内容の描画範囲と帯全体の背景を別々に固定する。
    content
      .clipped()
      .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
      .toolbarBackground(.visible, for: .windowToolbar)
  }
}

/// `NSWindow` を `AppNavigator` に渡す。SwiftUI にはメイン window が開いているかを問い合わせる
/// 手段が無い。
private struct MainWindowCapture: NSViewRepresentable {
  let navigator: AppNavigator

  func makeNSView(context: Context) -> CaptureView { CaptureView() }

  func updateNSView(_ view: CaptureView, context: Context) {
    view.navigator = navigator
    view.capture()
  }

  @MainActor
  final class CaptureView: NSView {
    weak var navigator: AppNavigator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      capture()
    }

    func capture() {
      if let window { navigator?.mainWindow = window }
    }
  }
}

private struct ProjectMenu: View {
  @ObservedObject var projects: ProjectsModel

  var body: some View {
    Menu {
      ForEach(projects.registry.projects, id: \.commonDirectory) { project in
        projectItem(project)
      }
    } label: {
      Label(projects.selectedProject?.displayName ?? "Project", systemImage: "folder")
        .labelStyle(.titleAndIcon)
    }
    .help("Project")
    .disabled(!projects.didLoad)
  }

  @ViewBuilder
  private func projectItem(_ project: RegisteredProject) -> some View {
    switch projects.slots[project.commonDirectory] {
    case .available:
      // `Toggle` で印を付ける。メニューの中の `Toggle` はチェックマーク付きの項目になる。
      Toggle(
        project.displayName,
        isOn: Binding(
          get: { projects.registry.selection == project.commonDirectory },
          set: { _ in projects.select(project.commonDirectory) }
        ))
    case .unavailable(let reason):
      // 到達不能な Project は選択できないので、選択中の Project 向けの「登録を解除」からは外せない。
      // 項目ごとのサブメニューに解除を置く (全 Project が到達不能で選択が無いときもここから外せる)。
      Menu("\(project.displayName) (到達不能: \(reason))") {
        Button("登録を解除") { Task { await projects.requestUnregister(project.commonDirectory) } }
      }
    case nil:
      Button(project.displayName) {}
        .disabled(true)
    }
  }
}

/// `NSOpenPanel` は選ばれた URL を返すだけで、repository root の抽出は `ProjectsModel` が git に
/// 問い合わせて行う (設計書 §16.1)。
@MainActor
func chooseProjectDirectory(_ projects: ProjectsModel) {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.prompt = "追加"
  panel.message = "登録する Git repository のフォルダを選んでください。"
  panel.begin { response in
    guard response == .OK, let url = panel.url else { return }
    Task { await projects.register(directory: url) }
  }
}
