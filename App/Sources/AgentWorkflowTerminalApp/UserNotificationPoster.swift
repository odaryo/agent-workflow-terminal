import Foundation
import TerminalCore
import UserNotifications

/// 通知を開いたときの移動先 (§11.2 の表)。
enum NotificationTarget: Sendable, Hashable {
  case pane(project: WorktreeIdentity, worktree: WorktreeIdentity, pane: PaneID)
  /// まとめ通知 (§11.2: 開くと Overview へ移る)。
  case overview

  private static let projectKey = "project"
  private static let worktreeKey = "worktree"
  private static let paneKey = "pane"

  var userInfo: [String: String] {
    switch self {
    case .pane(let project, let worktree, let pane):
      [
        Self.projectKey: project.rawValue, Self.worktreeKey: worktree.rawValue,
        Self.paneKey: pane.rawValue,
      ]
    case .overview: [:]
    }
  }

  /// 読めない値は Overview へ倒す。開いた通知が何もしないより、一覧を出す方が対象へ辿れる。
  init(userInfo: [AnyHashable: Any]) {
    guard let project = (userInfo[Self.projectKey] as? String).flatMap(WorktreeIdentity.init),
      let worktree = (userInfo[Self.worktreeKey] as? String).flatMap(WorktreeIdentity.init),
      let pane = userInfo[Self.paneKey] as? String
    else {
      self = .overview
      return
    }
    self = .pane(project: project, worktree: worktree, pane: PaneID(rawValue: pane))
  }
}

/// 通知1件の文面。コードや端末出力は載せない (§11.2 の最小 payload の原則をローカル通知にも
/// 適用する)。載せるのは名前・種類と、ハーネスが書いた現在地 (§12.7) の1行だけ。
struct PaneNotificationContent: Sendable, Hashable {
  let title: String
  let body: String
  let target: NotificationTarget

  static func summary(count: Int) -> Self {
    Self(title: "Agent Workflow Terminal", body: "判断待ちが \(count) 件あります", target: .overview)
  }

  /// 通知元の pane。`status` は連携由来の現在地 (§12.7) で、タスク完了のときだけ添える。
  struct Subject: Sendable, Hashable {
    let projectName: String
    let taskName: String
    let paneName: String
    let status: String?
    let target: NotificationTarget
  }

  static func pane(kind: PaneNotificationKind, subject: Subject, unknownMinutes: Int) -> Self {
    let label =
      switch kind {
      case .question: "Question — 質問への回答を待っています"
      case .permission: "Permission — 許可を待っています"
      case .error: "Error"
      case .attentionUnspecified: "要対応 (種別不明)"
      case .taskCompleted: "タスク完了"
      case .prolongedUnknown: "Unknown が \(unknownMinutes) 分続いています"
      }
    var body = "\(subject.paneName): \(label)"
    if kind == .taskCompleted, let status = subject.status, !status.isEmpty {
      body += "\n\(status)"
    }
    return Self(
      title: "\(subject.projectName) — \(subject.taskName)", body: body, target: subject.target)
  }
}

/// `UNUserNotificationCenter` の境界。bundle の外では作らない。
///
/// - Important: bundle identifier の無いプロセス (`swift run` など) で
///   `UNUserNotificationCenter.current()` を呼ぶと、`NSInternalInconsistencyException`
///   (`bundleProxyForCurrentProcess is nil`) で落ちる (実測: macOS 26、exit 134)。
@MainActor
final class UserNotificationPoster {
  private let center: UNUserNotificationCenter
  private let responder: NotificationResponder
  /// 許可の要求を1回にまとめる。並んで届いた通知がそれぞれ要求を出さないように。
  private var authorization: Task<Bool, Never>?

  /// `open` は通知を開いたときに main actor で呼ぶ。
  static func make(
    open: @escaping @MainActor @Sendable (NotificationTarget) async -> Void
  ) -> UserNotificationPoster? {
    guard Bundle.main.bundleIdentifier != nil else {
      NSLog("[app] bundle identifier が無いため、この起動では通知を無効にします")
      return nil
    }
    return UserNotificationPoster(open: open)
  }

  private init(open: @escaping @MainActor @Sendable (NotificationTarget) async -> Void) {
    center = UNUserNotificationCenter.current()
    responder = NotificationResponder(open: open)
    // 通知のクリックでアプリが起動した場合も取りこぼさないよう、起動処理の中で設定する
    // (`App.init` から呼ばれ、`applicationDidFinishLaunching` より前)。
    center.delegate = responder
  }

  func post(_ content: PaneNotificationContent) {
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: Self.makeContent(content), trigger: nil)
    Task {
      guard await isAuthorized() else { return }
      do {
        try await center.add(request)
      } catch {
        NSLog("[app] 通知を出せませんでした: \(error)")
      }
    }
  }

  /// 初回の許可要求は、最初に通知を出す必要が生じた時点で行う。許可されなければ通知しない
  /// (エラーにしない)。
  private func isAuthorized() async -> Bool {
    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional: return true
    case .notDetermined: break
    case .denied, .ephemeral: return false
    @unknown default: return false
    }
    if let authorization {
      return await authorization.value
    }
    let center = center
    let request = Task {
      do {
        return try await center.requestAuthorization(options: [.alert, .sound])
      } catch {
        NSLog("[app] 通知の許可を要求できませんでした: \(error)")
        return false
      }
    }
    authorization = request
    let granted = await request.value
    authorization = nil
    return granted
  }

  private static func makeContent(_ content: PaneNotificationContent) -> UNNotificationContent {
    let notification = UNMutableNotificationContent()
    notification.title = content.title
    notification.body = content.body
    notification.sound = .default
    notification.userInfo = content.target.userInfo
    return notification
  }
}

private final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
  private let open: @MainActor @Sendable (NotificationTarget) async -> Void

  init(open: @escaping @MainActor @Sendable (NotificationTarget) async -> Void) {
    self.open = open
  }

  /// これを返さないと、アプリが前面の間は macOS が通知を表示しない。前面でもタスク完了は出す
  /// (判断待ちの抑止は出す前に `PaneNotifier` が判定している)。
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
    let target = NotificationTarget(userInfo: response.notification.request.content.userInfo)
    await open(target)
  }
}
