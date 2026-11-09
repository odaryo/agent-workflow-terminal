import Testing
import UserNotifications

@testable import AgentWorkflowTerminalApp

@Suite("§11.2 macOS の通知の許可表示")
struct NotificationAuthorizationSummaryTests {
  @Test(
    "通知の許可状態を表示用に分類する",
    arguments: [
      (UNAuthorizationStatus.authorized, NotificationAuthorizationSummary.allowed),
      (.provisional, .allowed),
      (.denied, .denied),
      (.notDetermined, .notDetermined),
    ])
  func mapping(status: UNAuthorizationStatus, expected: NotificationAuthorizationSummary) {
    #expect(NotificationAuthorizationSummary(status) == expected)
  }

  @Test("未知の許可状態は確認できないと表示する")
  func unknownStatus() throws {
    let status = try #require(UNAuthorizationStatus(rawValue: 999))
    #expect(NotificationAuthorizationSummary(status) == .unknown)
  }

  @Test(
    "許可状態ごとのラベルと補足を表示する",
    arguments: [
      (NotificationAuthorizationSummary.allowed, "許可されています", nil as String?),
      (.denied, "拒否されています", "通知は表示されません。システム設定の「通知」で許可してください。"),
      (.notDetermined, "未決定", "最初の通知のときに確認します。"),
      (.unknown, "確認できません", nil),
    ])
  func wording(summary: NotificationAuthorizationSummary, label: String, detail: String?) {
    #expect(summary.label == label)
    #expect(summary.detail == detail)
  }
}
