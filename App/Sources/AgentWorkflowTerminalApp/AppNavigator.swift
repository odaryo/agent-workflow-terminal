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

  var isMainWindowOpen: Bool {
    guard let mainWindow else { return false }
    return mainWindow.isVisible || mainWindow.isMiniaturized
  }

  func toggleFromGlobalHotKey(selected model: AppModel?) {
    if NSApp.isActive, let mainWindow,
      mainWindow.isVisible, !mainWindow.isMiniaturized,
      mainWindow.isOnActiveSpace, mainWindow.isMainWindow
    {
      NSApp.hide(nil)
    } else {
      bringToFront(selected: model)
    }
  }

  func bringToFront(selected model: AppModel?) {
    NSApp.unhideWithoutActivation()
    if let mainWindow, !mainWindow.styleMask.contains(.fullScreen) {
      mainWindow.collectionBehavior.insert(.moveToActiveSpace)
    }
    if mainWindow?.isMiniaturized == true {
      mainWindow?.deminiaturize(nil)
    }
    if !isMainWindowOpen {
      openWindow?(id: "main")
    }
    mainWindow?.makeKeyAndOrderFront(nil)
    // 他のアプリが前面にいると activate() では拒まれることがある。
    NSApp.activate(ignoringOtherApps: true)
    model?.paneObservations.requestTerminalFocus()
    if let window = mainWindow, !window.styleMask.contains(.fullScreen) {
      // ⌘Tab や Dock の動きを変えないため戻すが、同じ runloop では window server に届く前に戻り、移動が効かないことがある (設計書 §5.4)。
      Task { @MainActor [weak window] in
        try? await Task.sleep(for: .seconds(0.5))
        window?.collectionBehavior.remove(.moveToActiveSpace)
      }
    }
  }

  /// Project → セッション → tmux の window と pane → メイン window の端末、の順に移す。`pane` が `nil`
  /// ならセッションまで。
  ///
  /// - Returns: pane へ移れなかった理由。セッションの選択は失敗しても済んでいる。
  func reveal(
    _ model: AppModel, worktree: WorktreeIdentity, session: TerminalSessionKey? = nil,
    pane: PaneID?, in projects: ProjectsModel
  ) async -> PaneRevealFailure? {
    projects.select(model.project.commonDirectory)
    if let session, model.sessionKeys.contains(session) {
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
    showOverviewSidebar()
  }

  func showOverviewSidebar(defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: OverviewSidebarPreferences.isOpenKey)
    openWindow?(id: "main")
    NSApp.activate()
  }

  /// メイン window が閉じていれば開いて、サイドバーを開いた状態にする。
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
