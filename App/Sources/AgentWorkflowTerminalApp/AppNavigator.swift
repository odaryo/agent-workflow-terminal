import Adapters
import AppKit
import SwiftUI
import TerminalCore

/// Overview の行の選択 (§13) と通知の deep link (§11.2) が共用する移動。
@MainActor
final class AppNavigator: ObservableObject {
  /// Overview の上に出す一行。
  @Published var overviewNotice: String?
  /// `openWindow` は View の environment からしか取れないので、window の root view が入れる。
  /// 通知を開いた経路 (`UNUserNotificationCenterDelegate`) には View が無い。
  var openWindow: OpenWindowAction?
  /// メイン window が閉じているかの判定用。`openWindow(id:)` は開いているかを返さない。
  weak var mainWindow: NSWindow?
  weak var overviewWindow: NSWindow?

  var isMainWindowOpen: Bool {
    guard let mainWindow else { return false }
    return mainWindow.isVisible || mainWindow.isMiniaturized
  }

  var isOverviewWindowOpen: Bool {
    guard let overviewWindow else { return false }
    return overviewWindow.isVisible || overviewWindow.isMiniaturized
  }

  /// Project → タブ → tmux の window と pane → メイン window の端末、の順に移す。`pane` が `nil`
  /// ならタブまで。
  ///
  /// - Returns: pane へ移れなかった理由。タブの選択は失敗しても済んでいる。
  func reveal(
    _ model: AppModel, worktree: WorktreeIdentity, session: TerminalSessionKey? = nil,
    pane: PaneID?, in projects: ProjectsModel
  ) async -> PaneRevealFailure? {
    projects.select(model.project.commonDirectory)
    if let session, model.tabKeys.contains(session) {
      model.select(session)
    } else if model.projectRoot?.identity == worktree {
      model.selectProjectRoot()
    } else if let task = model.worktrees.first(where: { $0.identity == worktree }) {
      model.select(task)
    }
    var failure: PaneRevealFailure?
    if let pane, let error = await model.paneObservations.reveal(pane) {
      failure = PaneRevealFailure(pane: pane, error: error)
    }
    openWindow?(id: "main")
    NSApp.activate()
    model.paneObservations.requestTerminalFocus()
    return failure
  }

  func showOverview(notice: String?) {
    overviewNotice = notice
    if OverviewPresentation.current() == .sidebar {
      showOverviewSidebar()
    } else {
      openWindow?(id: "overview")
      NSApp.activate()
    }
  }

  /// サイドバー表示で Overview を前に出す。Overview のウィンドウは開かない (§13)。
  func showOverviewSidebar(defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: OverviewSidebarPreferences.isOpenKey)
    openWindow?(id: "main")
    NSApp.activate()
  }

  /// ⌘⇧O のサイドバー表示での動作。メイン window が閉じていれば開いて、サイドバーを開いた状態にする。
  func toggleOverviewSidebar(
    openWindow: OpenWindowAction, defaults: UserDefaults = .standard
  ) {
    if isMainWindowOpen {
      let isOpen =
        defaults.object(forKey: OverviewSidebarPreferences.isOpenKey) as? Bool
        ?? OverviewSidebarPreferences.defaultIsOpen
      defaults.set(!isOpen, forKey: OverviewSidebarPreferences.isOpenKey)
    } else {
      defaults.set(true, forKey: OverviewSidebarPreferences.isOpenKey)
    }
    openWindow(id: "main")
    NSApp.activate()
  }
}

/// 観測は約2秒遅れるので、観測に残っている pane でも移動の時点で消えていることがある (Issue #402)。
enum PaneRevealFailure: Equatable, CustomStringConvertible {
  case paneGone(PaneID)
  case failed(PaneID, String)

  init(pane: PaneID, error: TmuxPaneOperationError) {
    if case .paneNotFound = error {
      self = .paneGone(pane)
    } else {
      self = .failed(pane, String(describing: error))
    }
  }

  var description: String {
    switch self {
    case .paneGone(let pane): "pane \(pane.rawValue) は既に終了しています。"
    case .failed(let pane, let error): "pane \(pane.rawValue) へ移動できません: \(error)"
    }
  }
}
