import AppKit
import Foundation
import TerminalCore

/// 登録済みの全 Project の pane 観測から Mac のローカル通知を出し、開いた通知を対象へ
/// 移す (設計書 §11.2)。アプリに1つ。
///
/// 判定は `PaneNotificationPlanner` に任せ、ここは入力の中継・文面・抑止・deep link だけを持つ。
@MainActor
final class PaneNotifier {
  static let goneNotice = "通知元は既に終了しています。"

  private var planner = PaneNotificationPlanner()
  private var poster: UserNotificationPoster?
  private let navigator: AppNavigator
  private weak var projects: ProjectsModel?
  private var deadline: Task<Void, Never>?
  private let clock = ContinuousClock()

  /// bundle の外では `nil` (通知を無効にして起動する。`UserNotificationPoster.make`)。
  static func make(navigator: AppNavigator) -> PaneNotifier? {
    let notifier = PaneNotifier(navigator: navigator)
    guard
      let poster = UserNotificationPoster.make(open: { [weak notifier] target in
        await notifier?.open(target)
      })
    else { return nil }
    notifier.poster = poster
    return notifier
  }

  private init(navigator: AppNavigator) {
    self.navigator = navigator
  }

  func attach(_ projects: ProjectsModel) {
    self.projects = projects
  }

  // MARK: - PaneObservationStore からの入力

  func observationStarted(_ worktree: WorktreeIdentity) {
    planner.startObserving(worktree, at: clock.now)
    deliver([])
  }

  func observationStopped(_ worktree: WorktreeIdentity) {
    planner.stopObserving(worktree)
    deliver([])
  }

  func statesObserved(_ snapshot: WorktreePaneAgentStates, in worktree: WorktreeIdentity) {
    refreshSettings()
    deliver(planner.observeStates(snapshot, in: worktree, at: clock.now))
  }

  /// `displays` はその worktree の全 pane の完了表示。
  func completionsObserved(
    _ displays: [PaneID: PaneTaskCompletionDisplay], in worktree: WorktreeIdentity
  ) {
    refreshSettings()
    deliver(planner.observeCompletions(displays, in: worktree, at: clock.now))
  }

  // MARK: - 出す

  private func refreshSettings() {
    planner.settings = NotificationPreferences.current()
  }

  /// Project の一覧と、各 Project の初回の worktree 検出が終わるまでは起動直後のまとめ通知を
  /// 待たせる。初回の検出が失敗した Project (`message`) は待たない。
  private var isSummaryGateOpen: Bool {
    guard let projects, projects.didLoad else { return false }
    return projects.availableModels.allSatisfy { $0.didCompleteInitialScan || $0.message != nil }
  }

  private func deliver(_ notifications: [PaneNotification]) {
    let now = clock.now
    let all = notifications + planner.setSummaryGate(isOpen: isSummaryGateOpen, at: now)
    let showing = showingWorktree
    for notification in all where !notification.isSuppressed(whileShowing: showing) {
      if let content = content(for: notification) {
        poster?.post(content)
      }
    }
    schedule()
  }

  /// アプリが前面で、メイン window に表示しているタブ。
  private var showingWorktree: WorktreeIdentity? {
    guard NSApp.isActive else { return nil }
    return projects?.selectedModel?.selectedIdentity
  }

  private func schedule() {
    deadline?.cancel()
    deadline = planner.nextDeadline.map { instant in
      Task { [weak self, clock] in
        do {
          try await clock.sleep(until: instant)
        } catch {
          return
        }
        guard let self else { return }
        self.deliver(self.planner.advance(to: instant))
      }
    }
  }

  private func content(for notification: PaneNotification) -> PaneNotificationContent? {
    switch notification {
    case .attentionSummary(let count):
      return .summary(count: count)
    case .pane(let event):
      guard let model = model(containing: event.worktree) else { return nil }
      let observed = model.paneObservations.observed[event.worktree]
      let detail = observed?.details[event.paneID]
      let subject = PaneNotificationContent.Subject(
        projectName: model.project.displayName,
        taskName: model.worktreeTitle(of: event.worktree),
        paneName: paneShortName(
          paneID: event.paneID, isMain: model.mainPane(of: event.worktree) == event.paneID,
          location: detail?.location),
        status: detail?.status,
        target: .pane(
          project: model.project.commonDirectory, worktree: event.worktree, pane: event.paneID))
      return .pane(
        kind: event.kind, subject: subject,
        unknownMinutes: Int(planner.settings.unknownThreshold.components.seconds / 60))
    }
  }

  private func model(containing worktree: WorktreeIdentity) -> AppModel? {
    projects?.availableModels.first { model in
      model.projectRoot?.identity == worktree
        || model.worktrees.contains { $0.identity == worktree }
    }
  }

  // MARK: - 開く

  /// §11.2 の表のとおり対象 pane まで移る。Question overlay (§11.1) は未実装なので、Question も
  /// pane まで。pane が既に無ければタブを、worktree も無ければ Overview を開き、通知元が
  /// 終了していることを出す。
  func open(_ target: NotificationTarget) async {
    guard let projects else { return }
    switch target {
    case .overview:
      navigator.showOverview(notice: nil)
    case .pane(let project, let worktree, let pane):
      guard
        let model = projects.availableModels.first(where: {
          $0.project.commonDirectory == project
        }),
        model.inventory.observesPaneStates(of: worktree)
      else {
        navigator.showOverview(notice: Self.goneNotice)
        return
      }
      let observed = model.paneObservations.observed[worktree]
      let paneExists =
        observed?.details[pane] != nil
        || observed?.paneStates?.contains { $0.id == pane } == true
      if paneExists {
        if let failure = await navigator.reveal(
          model, worktree: worktree, pane: pane, in: projects)
        {
          projects.showWarning(failure)
        }
      } else {
        _ = await navigator.reveal(model, worktree: worktree, pane: nil, in: projects)
        projects.showWarning(Self.goneNotice)
      }
    }
  }
}
