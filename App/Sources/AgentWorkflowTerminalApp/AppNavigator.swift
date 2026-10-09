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

  /// Project → タブ → tmux の window と pane → メイン window の端末、の順に移す。`pane` が `nil`
  /// ならタブまで。
  ///
  /// - Returns: pane へ移れなかった理由。
  func reveal(
    _ model: AppModel, worktree: WorktreeIdentity, pane: PaneID?, in projects: ProjectsModel
  ) async -> String? {
    projects.select(model.project.commonDirectory)
    if model.projectRoot?.identity == worktree {
      model.selectProjectRoot()
    } else if let task = model.worktrees.first(where: { $0.identity == worktree }) {
      model.select(task)
    }
    var failure: String?
    if let pane, let error = await model.paneObservations.reveal(pane) {
      failure = "pane \(pane.rawValue) へ移動できません: \(error)"
    }
    openWindow?(id: "main")
    NSApp.activate()
    model.paneObservations.requestTerminalFocus()
    return failure
  }

  func showOverview(notice: String?) {
    overviewNotice = notice
    openWindow?(id: "overview")
    NSApp.activate()
  }
}
