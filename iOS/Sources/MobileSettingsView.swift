import RemoteClient
import SwiftUI
import UIKit

@MainActor
struct MobileSettingsView: View {
  let model: MobileClientModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: RemoteHostSettings
  @State private var port: String

  init(model: MobileClientModel) {
    self.model = model
    _draft = State(initialValue: model.settings)
    _port = State(initialValue: String(model.settings.port))
  }

  private var candidate: RemoteHostSettings {
    RemoteHostSettings(
      host: draft.host, port: Int(port) ?? 0, user: draft.user, tmuxPath: draft.tmuxPath)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("接続先") {
          TextField("host", text: $draft.host)
            .keyboardType(.URL)
          problems(for: .host)
          TextField("port", text: $port)
            .keyboardType(.numberPad)
          problems(for: .port)
          TextField("user", text: $draft.user)
          problems(for: .user)
          TextField("tmuxPath", text: $draft.tmuxPath)
          problems(for: .tmuxPath)
        }
        Section("機器の公開鍵") {
          if model.publicKey.isEmpty {
            Text("公開鍵を読み込めませんでした。アプリを開き直してください。")
              .foregroundStyle(.red)
          } else {
            Text(model.publicKey)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
            Button("公開鍵をコピー") { UIPasteboard.general.string = model.publicKey }
            Text("Host の ~/.ssh/authorized_keys に、この公開鍵を1行追加してください。")
              .font(.caption)
          }
        }
        Section("承認済みの host key") {
          Text("\(model.settings.host):\(model.settings.port)")
          if let fingerprint = model.knownHosts.trustedFingerprint(
            host: model.settings.host, port: model.settings.port)
          {
            Text(fingerprint.rawValue)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
            Button("承認を削除", role: .destructive) {
              model.removeTrustedHost(settings: model.settings)
            }
          } else {
            Text("この接続先で承認済みの host key はありません")
              .foregroundStyle(.secondary)
          }
        }
        if let message = model.errorMessage {
          Section {
            Text(message).foregroundStyle(.red)
          }
        }
      }
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .navigationTitle("設定")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("キャンセル") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            if model.saveSettings(candidate) { dismiss() }
          }
          .disabled(!candidate.problems.isEmpty)
        }
      }
    }
  }

  private func problems(for field: Field) -> some View {
    ForEach(Array(candidate.problems.enumerated()), id: \.offset) { _, problem in
      let description = describe(problem)
      if description.field == field {
        Text(description.message)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private enum Field { case host, port, user, tmuxPath }

  private func describe(_ problem: RemoteHostSettings.Problem) -> (field: Field, message: String) {
    switch problem {
    case .emptyHost: return (.host, "host を入力してください")
    case .hostHasSurroundingWhitespace: return (.host, "host の前後の空白を取り除いてください")
    case .portOutOfRange: return (.port, "port は 1〜65535 の整数で入力してください")
    case .emptyUser: return (.user, "user を入力してください")
    case .userHasSurroundingWhitespace: return (.user, "user の前後の空白を取り除いてください")
    case .tmuxPathNotAbsolute: return (.tmuxPath, "tmuxPath は / で始まる絶対パスで入力してください")
    }
  }
}
