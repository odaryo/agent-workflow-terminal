import Citadel
import Crypto
import NIOCore
import NIOSSH
import SwiftTerm
import SwiftUI
import UIKit

struct ConnectionSettings {
    let host: String
    let port: Int
    let user: String
    let tmux: String

    var endpoint: String { "[\(host.lowercased())]:\(port)" }

    func validate() throws {
        guard !host.isEmpty, !user.isEmpty, (1...65535).contains(port), tmux.hasPrefix("/"),
            !tmux.contains("\n"), !tmux.contains("\r"), !tmux.contains("\0") else {
            throw SpikeError.message("host・user・port (1〜65535)・tmux の絶対パスを確認してください")
        }
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private enum TerminalInput {
    case bytes([UInt8])
    case resize(Int, Int)
}

@MainActor
final class ConnectionModel: ObservableObject {
    @Published var sessions: [String] = []
    @Published var selectedSession: String?
    @Published var status = "未接続"
    @Published var busy = false
    @Published var connected = false
    @Published var log = ""
    @Published var review: HostKeyReview?
    @Published var authorizedKey = ""

    private(set) var terminal = TerminalView(frame: .zero, font: nil)
    private var privateKey: Curve25519.Signing.PrivateKey?
    private var settings: ConnectionSettings?
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var client: SSHClient?
    private var input: AsyncStream<TerminalInput>.Continuation?
    private var backgrounded = false
    private var resumeOnActive = false

    init() {
        do {
            let key = try DeviceKey.loadOrCreate()
            privateKey = key
            authorizedKey = DeviceKey.authorizedKey(key)
            record("機器の鍵を Keychain から準備")
        } catch {
            status = error.localizedDescription
            record(status)
        }
    }

    func record(_ message: String) {
        log += "[\(Date().ISO8601Format())] \(message)\n"
    }

    func refresh(_ configuration: ConnectionSettings) {
        settings = configuration
        sessions = []
        start()
    }

    func select(_ session: String) {
        terminal = TerminalView(frame: .zero, font: nil)
        selectedSession = session
        start()
    }

    func reconnect() {
        record("再接続を要求: \(selectedSession ?? "session 一覧")")
        start()
    }

    func approveHostKey() {
        guard let review, review.saved == nil, review.endpoint == settings?.endpoint else { return }
        KnownHosts.save(review.received, for: review.endpoint)
        record("host key を承認: \(review.endpoint) \(HostKeyReview.fingerprint(review.received))")
        self.review = nil
        reconnect()
    }

    func forgetHostKey(_ endpoint: String) {
        stop(reason: "保存した host key を削除")
        KnownHosts.save(nil, for: endpoint)
        review = nil
    }

    func leaveTerminal() {
        stop(reason: "session 一覧へ戻るため切断")
        selectedSession = nil
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background {
            backgrounded = true
            resumeOnActive = selectedSession != nil
            stop(reason: "background: channel と SSH 接続を閉じる", background: true)
        } else if phase == .active {
            backgrounded = false
            if resumeOnActive {
                resumeOnActive = false
                reconnect()
            }
        }
    }

    func send(_ data: ArraySlice<UInt8>) {
        input?.yield(.bytes(Array(data)))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        input?.yield(.resize(cols, rows))
    }

    private func stop(reason: String, background: Bool = false) {
        generation = UUID()
        operation?.cancel()
        operation = nil
        input?.finish()
        input = nil
        let oldClient = client
        client = nil
        let previousClose = closing
        let backgroundTask = background
            ? UIApplication.shared.beginBackgroundTask(withName: "SSH detach", expirationHandler: nil) : .invalid
        closing = Task {
            await previousClose?.value
            if let oldClient {
                do { try await oldClient.close() }
                catch { record("SSH close 失敗: \(error.localizedDescription)") }
            }
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        busy = false
        connected = false
        status = "切断: \(reason)"
        record(status)
    }

    private func start() {
        guard !backgrounded, let settings else { return }
        stop(reason: "新しい接続を開始")
        let token = generation
        let session = selectedSession
        review = nil
        busy = true
        status = "接続中"
        operation = Task { await run(settings, session: session, token: token) }
    }

    private func run(_ settings: ConnectionSettings, session: String?, token: UUID) async {
        await closing?.value
        guard generation == token, !Task.isCancelled else { return }
        let saved = KnownHosts.key(for: settings.endpoint)
        let validator = HostKeyValidator(expected: saved)
        var opened: SSHClient?
        do {
            try settings.validate()
            guard let privateKey else { throw SpikeError.message("機器の秘密鍵がありません") }
            record("接続: \(settings.endpoint) user=\(settings.user)")
            record("公開鍵認証を開始")
            let ssh = try await SSHClient.connect(
                host: settings.host, port: settings.port,
                authenticationMethod: .ed25519(username: settings.user, privateKey: privateKey),
                hostKeyValidator: .custom(validator), reconnect: .never
            )
            opened = ssh
            guard generation == token, !Task.isCancelled else {
                try await ssh.close()
                return
            }
            client = ssh
            record("接続・host key 検証・公開鍵認証に成功")
            if let session {
                try await attach(ssh, settings: settings, session: session, token: token)
                if generation == token {
                    status = "切断: PTY が終了しました"
                    record(status)
                }
            } else {
                let output = try await ssh.executeCommand(
                    "\(shellQuote(settings.tmux)) list-sessions -F '#{session_name}'",
                    maxResponseSize: 1024 * 1024
                )
                guard generation == token else {
                    try await ssh.close()
                    return
                }
                sessions = String(decoding: output.readableBytesView, as: UTF8.self)
                    .split(separator: "\n").map(String.init)
                status = "session 一覧: \(sessions.count) 件"
                record(status)
            }
        } catch {
            if generation == token {
                if let received = validator.received {
                    review = HostKeyReview(endpoint: settings.endpoint, received: received, saved: saved)
                    status = saved == nil ? "host key の承認待ち" : "host key 不一致: 接続を拒否"
                    record("\(status): 今回 \(HostKeyReview.fingerprint(received))")
                    if let saved { record("保存済み \(HostKeyReview.fingerprint(saved))") }
                } else {
                    status = "切断 / 接続失敗: \(error.localizedDescription)"
                    record(status)
                }
            }
        }
        if let opened {
            do { try await opened.close() }
            catch { if generation == token { record("SSH close 失敗: \(error.localizedDescription)") } }
        }
        if generation == token {
            client = nil
            input?.finish()
            input = nil
            connected = false
            busy = false
            operation = nil
            record("SSH 接続を終了")
        }
    }

    private func attach(_ ssh: SSHClient, settings: ConnectionSettings, session: String, token: UUID) async throws {
        terminal.layoutIfNeeded()
        let size = terminal.terminalDimensions
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: size.cols, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])
        )
        try await ssh.withPTY(request) { inbound, writer in
            guard self.generation == token, !Task.isCancelled else { throw CancellationError() }
            let (events, continuation) = AsyncStream<TerminalInput>.makeStream()
            self.input = continuation
            defer {
                continuation.finish()
                if self.generation == token { self.input = nil }
            }
            let command = "exec \(shellQuote(settings.tmux)) attach-session -t \(shellQuote("=" + session))\n"
            try await writer.write(ByteBuffer(string: command))
            guard self.generation == token, !Task.isCancelled else { throw CancellationError() }
            let current = self.terminal.terminalDimensions
            continuation.yield(.resize(current.cols, current.rows))
            self.busy = false
            self.connected = true
            self.status = "attach 要求送信済み: \(session)"
            self.record("attach 要求送信: \(session) (\(size.cols)×\(size.rows))")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.readOutput(inbound, token: token)
                }
                group.addTask {
                    for await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .bytes(let bytes):
                            try await writer.write(ByteBuffer(bytes: bytes))
                        case .resize(let cols, let rows):
                            try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                        }
                    }
                }
                defer {
                    continuation.finish()
                    group.cancelAll()
                }
                try await group.next()
            }
        }
    }

    private func readOutput(_ inbound: TTYOutput, token: UUID) async throws {
        for try await output in inbound {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            switch output {
            case .stdout(let buffer), .stderr(let buffer):
                terminal.feed(byteArray: Array(buffer.readableBytesView)[...])
            }
        }
    }
}
