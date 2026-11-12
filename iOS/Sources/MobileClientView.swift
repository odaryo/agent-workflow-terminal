import RemoteClient
import SwiftUI

@MainActor
struct MobileClientView: View {
  let model: MobileClientModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingSettings = false

  var body: some View {
    NavigationStack {
      Group {
        if model.isShowingTerminal {
          terminalScreen
        } else {
          sessionList
        }
      }
      .safeAreaInset(edge: .bottom) {
        if let message = model.errorMessage {
          Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
      }
    }
    .sheet(isPresented: $showingSettings) {
      MobileSettingsView(model: model)
    }
    .alert(
      "host key の承認",
      isPresented: Binding(
        get: { model.approval != nil },
        set: { _ in }
      ),
      presenting: model.approval
    ) { request in
      Button("承認") { model.answerHostKey(true, requestID: request.id) }
      Button("拒否", role: .cancel) { model.answerHostKey(false, requestID: request.id) }
    } message: { request in
      Text(
        "\(request.settings.host):\(request.settings.port)\n\(request.fingerprint.rawValue)\n"
          + "Host の Mac で ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub を実行すると、同じ指紋を確認できます。")
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background: model.enteredBackground()
      case .active: model.enteredForeground()
      case .inactive: break
      @unknown default: break
      }
    }
  }

  private var sessionList: some View {
    List {
      Section("接続先") {
        if model.settings.problems.isEmpty {
          Text("\(model.settings.user)@\(model.settings.host):\(model.settings.port)")
        } else {
          Text("接続先は未設定です")
          Button("設定を開く") { showingSettings = true }
        }
      }
      Section("session") {
        ForEach(model.sessions) { session in
          Button {
            model.attach(name: session.name)
          } label: {
            HStack {
              Text(session.name)
              Spacer()
              Text("接続中の client: \(session.attachedClients)")
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .disabled(!model.canRefresh)
        }
        if let message = model.listMessage {
          Text(message).foregroundStyle(.secondary)
        }
        if model.isRefreshing { ProgressView("一覧を更新中") }
      }
    }
    .navigationTitle("AWT")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("設定") { showingSettings = true }
          .disabled(model.isRefreshing)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("更新") { model.refresh() }
          .disabled(!model.canRefresh)
      }
    }
  }

  private var terminalScreen: some View {
    ZStack {
      if let terminal = model.terminal {
        RemoteTerminalView(terminal: terminal)
          .id(ObjectIdentifier(terminal))
      }
      switch model.lifecycle.state {
      case .attaching:
        ProgressView("接続中")
          .padding()
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      case .disconnected:
        VStack(spacing: 16) {
          Text("接続が切れました")
          Button("再接続") { model.handle(.reconnectRequested) }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      case .suspended:
        Text("バックグラウンドで接続を切断しました")
          .padding()
          .background(.regularMaterial)
      case .idle, .attached:
        EmptyView()
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("一覧へ戻る") { model.handle(.detachRequested) }
      }
    }
  }
}
