import SwiftUI
import UIKit

@main
@MainActor
struct Gate2iPadApp: App {
    @StateObject private var model = ConnectionModel()

    var body: some Scene {
        WindowGroup { SpikeView(model: model) }
    }
}

@MainActor
struct SpikeView: View {
    @ObservedObject var model: ConnectionModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("gate2.host") private var host = ""
    @AppStorage("gate2.port") private var port = "22"
    @AppStorage("gate2.user") private var user = ""
    @AppStorage("gate2.tmux") private var tmux = "/opt/homebrew/bin/tmux"
    @State private var logsExpanded = false

    private var settings: ConnectionSettings {
        ConnectionSettings(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port) ?? 0,
            user: user.trimmingCharacters(in: .whitespacesAndNewlines), tmux: tmux
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Gate 2 iPad").font(.headline)
                Spacer()
                if model.selectedSession != nil {
                    Button("session 一覧へ") { model.leaveTerminal() }
                }
            }
            Text(model.status).font(.caption).textSelection(.enabled)
            if let session = model.selectedSession {
                HStack {
                    Text(session).lineLimit(1)
                    Spacer()
                    if !model.connected {
                        Button("再接続") { model.reconnect() }.disabled(model.busy)
                    }
                }
                hostKeyReview
                TerminalSurface(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("接続設定 (自動保存)") {
                        TextField("host / Tailscale IP・DNS 名", text: $host)
                        TextField("port", text: $port).keyboardType(.numberPad)
                        TextField("user", text: $user)
                        TextField("tmux の絶対パス", text: $tmux)
                        Button("接続して session 一覧を更新") { model.refresh(settings) }
                            .disabled(model.busy || model.authorizedKey.isEmpty)
                        Button("この host:port の保存した鍵を削除", role: .destructive) {
                            model.forgetHostKey(settings.endpoint)
                        }
                        .disabled(model.busy)
                    }
                    .disabled(model.busy)
                    Section("機器の公開鍵") {
                        Text(model.authorizedKey.isEmpty ? "鍵の準備に失敗しました" : model.authorizedKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("公開鍵をコピー") { UIPasteboard.general.string = model.authorizedKey }
                            .disabled(model.authorizedKey.isEmpty)
                    }
                    Section("host key") { hostKeyReview }
                    Section("tmux sessions") {
                        ForEach(model.sessions, id: \.self) { session in
                            Button(session) { model.select(session) }.disabled(model.busy)
                        }
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            DisclosureGroup("接続ログ", isExpanded: $logsExpanded) {
                Button("ログ全文をコピー") { UIPasteboard.general.string = model.log }
                ScrollView {
                    Text(model.log)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
            }
        }
        .padding(8)
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
    }

    @ViewBuilder
    private var hostKeyReview: some View {
        if let review = model.review {
            VStack(alignment: .leading, spacing: 6) {
                Text(review.endpoint)
                Text("今回: \(HostKeyReview.fingerprint(review.received))")
                if let saved = review.saved {
                    Text("保存済み: \(HostKeyReview.fingerprint(saved))")
                    Text("鍵が一致しないため接続を拒否しました。Host 側の鍵を確認してください。")
                } else {
                    Text("Host 上で確認した指紋と一致する場合だけ承認してください。")
                    Button("この鍵を承認して再接続") { model.approveHostKey() }
                        .disabled(model.busy)
                }
            }
            .font(.caption)
            .textSelection(.enabled)
        } else {
            Text("初回接続で指紋を表示します。保存済みと違う鍵は拒否します。")
                .font(.caption)
        }
    }
}
