import AppKit
import SwiftUI
import TerminalCore

struct ProjectsWindowContent: View {
  @ObservedObject var projects: ProjectsModel
  @Environment(\.openWindow) private var openWindow
  @AppStorage(OverviewSidebarPreferences.isOpenKey) private var isSidebarOpen =
    OverviewSidebarPreferences.defaultIsOpen
  @AppStorage(OverviewSidebarPreferences.widthKey) private var sidebarWidth =
    OverviewSidebarPreferences.defaultWidth
  @State private var pendingAgentCommand: AgentCommandSheetItem?

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
    .sheet(item: $pendingAgentCommand) { item in
      ProjectAgentCommandSheet(project: item.project, projects: projects)
    }
    .task { projects.start() }
    .onAppear { projects.navigator.openWindow = openWindow }
    .onAppear { projects.startGlobalHotKey() }
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
      OverviewView(projects: projects, navigator: projects.navigator) {
        pendingAgentCommand = AgentCommandSheetItem(project: $0)
      }
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
      // (session は残る)。セッションのように opacity で重ねると前の Project の client が attach した
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
        description: Text("登録済みの Project にはどれも到達できません。設定画面の「Project」から理由を確認してください。"))
    }
  }
}

private struct AgentCommandSheetItem: Identifiable {
  let project: RegisteredProject
  var id: WorktreeIdentity { project.commonDirectory }
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
