import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§11.2 通知の文面と開いたときの移動先")
struct PaneNotificationContentTests {
  private let project: WorktreeIdentity
  private let worktree: WorktreeIdentity

  init() throws {
    project = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/login"))
  }

  @Test("Project 名・タスク名・pane の呼び名・種類を載せる")
  func paneContent() {
    let content = PaneNotificationContent.pane(
      kind: .permission, subject: subject(paneName: "メイン", status: "設計相談中"),
      unknownMinutes: 10)

    #expect(content.title == "repo — fix-login")
    #expect(content.body == "メイン: Permission — 許可を待っています")
    #expect(content.target == target)
  }

  @Test("タスク完了には現在地を1行添え、判断待ちには添えない")
  func completionCarriesStatus() {
    let completed = PaneNotificationContent.pane(
      kind: .taskCompleted, subject: subject(paneName: "0.1", status: "PR を作成した"),
      unknownMinutes: 10)
    let question = PaneNotificationContent.pane(
      kind: .question, subject: subject(paneName: "0.1", status: "PR を作成した"),
      unknownMinutes: 10)

    #expect(completed.body == "0.1: タスク完了\nPR を作成した")
    #expect(!question.body.contains("PR を作成した"))
  }

  @Test("まとめ通知は件数だけを載せ、Overview へ移る")
  func summaryContent() {
    let content = PaneNotificationContent.summary(count: 3)

    #expect(content.body == "判断待ちが 3 件あります")
    #expect(content.target == .overview)
  }

  @Test("移動先は userInfo を往復し、読めなければ Overview へ倒す")
  func targetRoundTrip() {
    #expect(NotificationTarget(userInfo: target.userInfo) == target)
    #expect(NotificationTarget(userInfo: NotificationTarget.overview.userInfo) == .overview)
    #expect(NotificationTarget(userInfo: ["project": "relative"]) == .overview)
  }

  @Test("pane の呼び名は Overview と同じ (メイン / window.pane / pane ID)")
  func paneNames() {
    let pane = PaneID(rawValue: "%7")
    let location = PaneLocation(windowIndex: 1, paneIndex: 2)

    #expect(paneShortName(paneID: pane, isMain: true, location: location) == "メイン")
    #expect(paneShortName(paneID: pane, isMain: false, location: location) == "1.2")
    #expect(paneShortName(paneID: pane, isMain: false, location: nil) == "%7")
  }

  @Test("設定が未保存の種類は既定値として読む")
  func preferencesDefaults() throws {
    let suite = "PaneNotificationContentTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(NotificationPreferences.current(defaults) == PaneNotificationSettings())

    defaults.set(false, forKey: NotificationPreferences.key(.question))
    defaults.set(true, forKey: NotificationPreferences.key(.prolongedUnknown))
    defaults.set(3, forKey: NotificationPreferences.unknownMinutesKey)
    let changed = NotificationPreferences.current(defaults)
    #expect(!changed.enabledKinds.contains(.question))
    #expect(changed.enabledKinds.contains(.prolongedUnknown))
    #expect(changed.unknownThreshold == .seconds(180))
  }

  private func subject(paneName: String, status: String?) -> PaneNotificationContent.Subject {
    PaneNotificationContent.Subject(
      projectName: "repo", taskName: "fix-login", paneName: paneName, status: status,
      target: target)
  }

  private var target: NotificationTarget {
    .pane(project: project, worktree: worktree, pane: PaneID(rawValue: "%3"))
  }
}
