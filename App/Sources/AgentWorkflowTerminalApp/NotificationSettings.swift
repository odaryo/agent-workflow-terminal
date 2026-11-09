import AppKit
import SwiftUI
import TerminalCore
import UserNotifications

enum NotificationAuthorizationSummary: Sendable, Equatable {
  case allowed
  case denied
  case notDetermined
  case unknown

  init(_ status: UNAuthorizationStatus) {
    switch status {
    case .authorized, .provisional: self = .allowed
    case .denied: self = .denied
    case .notDetermined: self = .notDetermined
    default: self = .unknown
    }
  }

  var label: String {
    switch self {
    case .allowed: "許可されています"
    case .denied: "拒否されています"
    case .notDetermined: "未決定"
    case .unknown: "確認できません"
    }
  }

  var detail: String? {
    switch self {
    case .allowed, .unknown: nil
    case .denied: "通知は表示されません。システム設定の「通知」で許可してください。"
    case .notDetermined: "最初の通知のときに確認します。"
    }
  }
}

/// 通知の種類ごとの ON / OFF と、長時間 `Unknown` の継続時間 (設計書 §11.2)。UserDefaults に置く。
enum NotificationPreferences {
  static let unknownMinutesKey = "notifications.prolongedUnknownMinutes"
  static let defaultUnknownMinutes = 10

  static func key(_ kind: PaneNotificationKind) -> String {
    "notifications.\(kind.rawValue)"
  }

  static func isEnabledByDefault(_ kind: PaneNotificationKind) -> Bool {
    PaneNotificationSettings.defaultEnabledKinds.contains(kind)
  }

  /// 書かれていない key は既定値として読む。`bool(forKey:)` は未設定を `false` と返すので使わない
  /// — 既定 ON の種類が、設定画面を開く前は OFF になる。
  static func current(_ defaults: UserDefaults = .standard) -> PaneNotificationSettings {
    let enabled = PaneNotificationKind.allCases.filter { kind in
      defaults.object(forKey: key(kind)) as? Bool ?? isEnabledByDefault(kind)
    }
    let minutes = defaults.object(forKey: unknownMinutesKey) as? Int ?? defaultUnknownMinutes
    return PaneNotificationSettings(
      enabledKinds: Set(enabled), unknownThreshold: .seconds(max(1, minutes) * 60))
  }
}

extension PaneNotificationKind {
  var settingsLabel: String {
    switch self {
    case .question: "Question"
    case .permission: "Permission"
    case .error: "Error"
    case .attentionUnspecified: "要対応 (種別不明)"
    case .taskCompleted: "タスク完了"
    case .prolongedUnknown: "長時間の Unknown"
    }
  }
}

/// ⌘, の設定画面。
@MainActor
struct NotificationSettingsView: View {
  @State private var authorizationSummary: NotificationAuthorizationSummary?
  @AppStorage(NotificationPreferences.key(.question)) private var question =
    NotificationPreferences.isEnabledByDefault(.question)
  @AppStorage(NotificationPreferences.key(.permission)) private var permission =
    NotificationPreferences.isEnabledByDefault(.permission)
  @AppStorage(NotificationPreferences.key(.error)) private var error =
    NotificationPreferences.isEnabledByDefault(.error)
  @AppStorage(NotificationPreferences.key(.attentionUnspecified)) private var attentionUnspecified =
    NotificationPreferences.isEnabledByDefault(.attentionUnspecified)
  @AppStorage(NotificationPreferences.key(.taskCompleted)) private var taskCompleted =
    NotificationPreferences.isEnabledByDefault(.taskCompleted)
  @AppStorage(NotificationPreferences.key(.prolongedUnknown)) private var prolongedUnknown =
    NotificationPreferences.isEnabledByDefault(.prolongedUnknown)
  @AppStorage(NotificationPreferences.unknownMinutesKey) private var unknownMinutes =
    NotificationPreferences.defaultUnknownMinutes

  var body: some View {
    Form {
      Section("macOS の通知の許可") {
        if let summary = authorizationSummary {
          Text(summary.label)
          if let detail = summary.detail {
            Text(detail)
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Text("確認中…")
        }
      }
      Section("判断待ち") {
        Toggle(PaneNotificationKind.question.settingsLabel, isOn: $question)
        Toggle(PaneNotificationKind.permission.settingsLabel, isOn: $permission)
        Toggle(PaneNotificationKind.error.settingsLabel, isOn: $error)
        Toggle(PaneNotificationKind.attentionUnspecified.settingsLabel, isOn: $attentionUnspecified)
      }
      Section {
        Toggle(PaneNotificationKind.taskCompleted.settingsLabel, isOn: $taskCompleted)
      } footer: {
        Text("ハーネスが明示したタスク完了だけを通知します。pane の応答終了では通知しません。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Toggle(PaneNotificationKind.prolongedUnknown.settingsLabel, isOn: $prolongedUnknown)
        Stepper(value: $unknownMinutes, in: 1...240) {
          Text("継続時間: \(unknownMinutes) 分")
        }
        .disabled(!prolongedUnknown)
      } footer: {
        Text("Unknown は状態を判定できないことを表すだけで、対応が要るとは限りません。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .task {
      authorizationSummary = await UserNotificationPoster.authorizationSummary()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      Task {
        authorizationSummary = await UserNotificationPoster.authorizationSummary()
      }
    }
  }
}
