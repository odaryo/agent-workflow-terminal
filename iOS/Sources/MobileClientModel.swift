import CryptoKit
import Foundation
import Observation
import RemoteClient

@MainActor
@Observable
final class MobileClientModel {
  struct HostKeyApproval: Identifiable {
    let id: UUID
    let settings: RemoteHostSettings
    let fingerprint: SSHHostKeyFingerprint
  }

  private(set) var settings: RemoteHostSettings
  private(set) var knownHosts: KnownHosts
  private(set) var publicKey = ""
  private(set) var lifecycle = AttachLifecycle()
  private(set) var sessions: [RemoteTmuxSession] = []
  private(set) var listMessage: String?
  private(set) var errorMessage: String?
  private(set) var isRefreshing = false
  private(set) var terminal: MobileTerminal?
  private(set) var approval: HostKeyApproval?

  @ObservationIgnored private let store: any ClientSettingsStoring
  @ObservationIgnored private var privateKey: Curve25519.Signing.PrivateKey?
  @ObservationIgnored private var attempts: [Int: MobileConnectionAttempt] = [:]
  @ObservationIgnored private var refreshAttempt: MobileConnectionAttempt?
  @ObservationIgnored private var approvalReply: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var isInBackground = false

  init() {
    let store = ClientSettingsStore()
    self.store = store
    settings = store.loadSettings()
    knownHosts = store.loadKnownHosts()
    do {
      let key = try DeviceKeyStore().loadOrCreate()
      privateKey = key
      publicKey = try SSHEd25519PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        .authorizedKeysLine(comment: "AWT iPad")
    } catch {
      errorMessage = "機器の SSH 鍵を読み込めませんでした。アプリを開き直してください。"
    }
  }

  var isShowingTerminal: Bool { lifecycle.state != .idle }
  var canRefresh: Bool {
    settings.problems.isEmpty && privateKey != nil && !isRefreshing
      && !isShowingTerminal && !isInBackground
  }

  @discardableResult
  func saveSettings(_ value: RemoteHostSettings) -> Bool {
    guard value.problems.isEmpty, !isRefreshing, !isShowingTerminal else { return false }
    do {
      try store.saveSettings(value)
      settings = value
      sessions = []
      listMessage = nil
      errorMessage = nil
      return true
    } catch {
      errorMessage = "接続先を保存できませんでした。"
      return false
    }
  }

  func removeTrustedHost(settings: RemoteHostSettings) {
    var updated = knownHosts
    updated.remove(host: settings.host, port: settings.port)
    do {
      try store.saveKnownHosts(updated)
      knownHosts = updated
    } catch {
      errorMessage = "host key の承認を削除できませんでした。"
    }
  }

  func refresh() {
    guard canRefresh else { return }
    let attempt = MobileConnectionAttempt(settings: settings)
    refreshAttempt = attempt
    isRefreshing = true
    errorMessage = nil
    listMessage = nil
    sessions = []
    attempt.task = Task { [weak self] in
      guard let self else { return }
      defer {
        finishApproval(for: attempt)
        attempt.close()
        if refreshAttempt === attempt {
          refreshAttempt = nil
          isRefreshing = false
        }
      }
      do {
        let connection = try await connect(attempt)
        let outcome = try await listSessions(connection, settings: attempt.settings)
        try Task.checkCancellation()
        switch outcome {
        case .sessions(let result):
          sessions = result.sessions
          if !result.failures.isEmpty {
            listMessage = "読めなかった行が \(result.failures.count) 行あります"
          } else if result.sessions.isEmpty {
            listMessage = "tmux の session がありません"
          }
        case .noServer:
          listMessage = "tmux の session がありません"
        case .failed(_, let message):
          errorMessage = "session の一覧を取得できませんでした: \(oneLine(message))"
        }
      } catch {
        if !Task.isCancelled { errorMessage = failure(error, attempt: attempt).message }
      }
    }
  }

  func attach(name: String) {
    guard canRefresh else { return }
    errorMessage = nil
    handle(.attachRequested(name))
  }

  func handle(_ event: AttachLifecycle.Event) {
    let effects = lifecycle.handle(event)
    for effect in effects {
      switch effect {
      case .connectAndAttach(let name, let generation):
        errorMessage = nil
        startAttach(name: name, generation: generation)
      case .disconnect(let generation):
        disconnect(generation: generation)
      }
    }
    if lifecycle.state == .idle { terminal = nil }
  }

  func enteredBackground() {
    isInBackground = true
    if let attempt = refreshAttempt {
      finishApproval(for: attempt)
      attempt.close()
      refreshAttempt = nil
      isRefreshing = false
    }
    handle(.enteredBackground)
  }

  func enteredForeground() {
    isInBackground = false
    handle(.enteredForeground)
  }

  func answerHostKey(_ accepted: Bool, requestID: UUID? = nil) {
    guard let request = approval, requestID == nil || requestID == request.id else { return }
    var result = false
    if accepted {
      var updated = knownHosts
      updated.trust(
        host: request.settings.host, port: request.settings.port, fingerprint: request.fingerprint)
      do {
        try store.saveKnownHosts(updated)
        knownHosts = updated
        result = true
      } catch {
        errorMessage = "host key の承認を保存できなかったため、接続を拒否しました。"
      }
    }
    let reply = approvalReply
    approvalReply = nil
    approval = nil
    reply?.resume(returning: result)
  }

  private func startAttach(name: String, generation: Int) {
    let attempt = MobileConnectionAttempt(settings: settings)
    let surface = MobileTerminal()
    terminal = surface
    attempts[generation] = attempt
    attempt.terminal = surface
    attempt.task = Task { [weak self] in
      guard let self else { return }
      do {
        guard await surface.waitForLayout() else { throw CancellationError() }
        let connection = try await connect(attempt)
        let outcome = try await listSessions(connection, settings: attempt.settings)
        try Task.checkCancellation()
        let session = try session(named: name, outcome: outcome)
        let size = surface.dimensions
        let channel = try await connection.openTerminal(
          command: RemoteTmuxCommand.attach(
            tmuxPath: attempt.settings.tmuxPath, sessionID: session.id),
          columns: size.cols, rows: size.rows,
          onOutput: { [weak surface] bytes in
            guard let surface else { return }
            DispatchQueue.main.async {
              MainActor.assumeIsolated { surface.feed(bytes) }
            }
          },
          onClose: { [weak self] status in
            guard let self else { return }
            DispatchQueue.main.async {
              MainActor.assumeIsolated {
                self.terminalClosed(generation: generation, exitStatus: status)
              }
            }
          })
        if Task.isCancelled {
          channel.close()
          throw CancellationError()
        }
        attempt.channel = channel
        surface.channel = channel
        let currentSize = surface.dimensions
        channel.resize(columns: currentSize.cols, rows: currentSize.rows)
        handle(.attachSucceeded(generation: generation))
      } catch {
        let reason = failure(error, attempt: attempt)
        let previous = lifecycle
        handle(.attachFailed(generation: generation, retryable: reason.retryable))
        if previous != lifecycle { errorMessage = reason.message }
        disconnect(generation: generation)
      }
    }
  }

  private func terminalClosed(generation: Int, exitStatus: Int?) {
    let previous = lifecycle
    handle(.channelClosed(generation: generation, exitStatus: exitStatus))
    if previous != lifecycle, exitStatus == nil {
      errorMessage = "接続が切れました。接続先とネットワークを確認してください。"
    }
    disconnect(generation: generation)
  }

  private func disconnect(generation: Int) {
    guard let attempt = attempts.removeValue(forKey: generation) else { return }
    finishApproval(for: attempt)
    attempt.close()
  }

  private func connect(_ attempt: MobileConnectionAttempt) async throws -> SSHConnection {
    guard let privateKey else { throw MobileClientFailure.keyUnavailable }
    try Task.checkCancellation()
    let connection = try await SSHConnection.connect(
      settings: attempt.settings, privateKey: privateKey,
      hostKeyDecision: { [weak self, weak attempt] fingerprint in
        guard let self, let attempt else { return false }
        return await self.decideHostKey(fingerprint, attempt: attempt)
      })
    if Task.isCancelled {
      connection.close()
      throw CancellationError()
    }
    attempt.connection = connection
    finishApproval(for: attempt)
    return connection
  }

  private func decideHostKey(
    _ fingerprint: SSHHostKeyFingerprint, attempt: MobileConnectionAttempt
  ) async -> Bool {
    guard !attempt.isClosed else { return false }
    let settings = attempt.settings
    switch knownHosts.verdict(host: settings.host, port: settings.port, fingerprint: fingerprint) {
    case .trusted:
      return true
    case .mismatch(let trusted):
      attempt.hostKeyRejection =
        "host key が不一致のため接続を拒否しました（承認済み: \(trusted.rawValue)、今回: \(fingerprint.rawValue)）。"
      return false
    case .unknown:
      attempt.hostKeyRejection = "host key が承認されなかったため接続を拒否しました。"
      return await withCheckedContinuation { reply in
        approval = HostKeyApproval(id: attempt.id, settings: settings, fingerprint: fingerprint)
        approvalReply = reply
      }
    }
  }

  private func finishApproval(for attempt: MobileConnectionAttempt) {
    if approval?.id == attempt.id { answerHostKey(false) }
  }

  private func listSessions(
    _ connection: SSHConnection, settings: RemoteHostSettings
  ) async throws -> RemoteTmuxSessionList.Outcome {
    let result = try await connection.run(
      RemoteTmuxCommand.listSessions(tmuxPath: settings.tmuxPath))
    return RemoteTmuxSessionList.outcome(
      exitStatus: result.exitStatus, stdout: result.stdout, stderr: result.stderr)
  }

  private func session(
    named name: String, outcome: RemoteTmuxSessionList.Outcome
  ) throws -> RemoteTmuxSession {
    switch outcome {
    case .sessions(let result):
      guard let session = result.session(named: name) else {
        throw MobileClientFailure.sessionMissing
      }
      return session
    case .noServer:
      throw MobileClientFailure.sessionMissing
    case .failed(_, let message):
      throw MobileClientFailure.listFailed(message)
    }
  }

  private func failure(
    _ error: any Error, attempt: MobileConnectionAttempt
  ) -> (message: String, retryable: Bool) {
    if let failure = error as? MobileClientFailure {
      switch failure {
      case .sessionMissing:
        return ("選んだ session が見つかりません。一覧を更新してください。", false)
      case .listFailed(let message):
        return ("session の一覧を取得できませんでした: \(oneLine(message))", true)
      case .keyUnavailable:
        return ("機器の SSH 鍵を読み込めませんでした。", false)
      }
    }
    switch SSHConnectionError.wrapping(error) {
    case .hostKeyRejected:
      return (attempt.hostKeyRejection ?? "host key の承認が拒否されました。", false)
    case .authenticationFailed:
      return ("認証に失敗しました。公開鍵を Host の ~/.ssh/authorized_keys に登録してください。", false)
    case .connectionFailed:
      return ("接続に失敗しました。接続先とネットワークを確認してください。", true)
    }
  }

  private func oneLine(_ message: String) -> String {
    message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

private enum MobileClientFailure: Error {
  case sessionMissing
  case listFailed(String)
  case keyUnavailable
}

@MainActor
private final class MobileConnectionAttempt {
  let id = UUID()
  let settings: RemoteHostSettings
  var task: Task<Void, Never>?
  var connection: SSHConnection?
  var channel: SSHTerminalChannel?
  var terminal: MobileTerminal?
  var hostKeyRejection: String?
  private(set) var isClosed = false

  init(settings: RemoteHostSettings) { self.settings = settings }

  func close() {
    isClosed = true
    task?.cancel()
    task = nil
    terminal?.close()
    channel?.close()
    connection?.close()
    terminal = nil
    channel = nil
    connection = nil
  }
}
