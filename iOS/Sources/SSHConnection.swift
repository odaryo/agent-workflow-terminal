import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH
import RemoteClient

protocol SSHConnecting: Sendable {
  var isActive: Bool { get }
  // spec の公開 API は終了状態と stdout・stderr を個別に返す。
  // swiftlint:disable:next large_tuple
  func run(_ command: String) async throws -> (exitStatus: Int?, stdout: String, stderr: String)
  func openTerminal(
    command: String, columns: Int, rows: Int,
    onOutput: @escaping @Sendable ([UInt8]) -> Void,
    onClose: @escaping @Sendable (Int?) -> Void
  ) async throws -> SSHTerminalChannel
  func close()
}

enum SSHConnectionError: Error, Sendable {
  case hostKeyRejected(SSHHostKeyFingerprint)
  case authenticationFailed
  case connectionFailed(String)

  static func wrapping(_ error: any Error) -> Self {
    error as? Self ?? .connectionFailed(String(describing: error))
  }
}

struct SSHConnection: SSHConnecting {
  private let channel: any Channel

  var isActive: Bool { channel.isActive }

  static func connect(
    settings: RemoteHostSettings, privateKey: Curve25519.Signing.PrivateKey,
    hostKeyDecision: @escaping @Sendable (SSHHostKeyFingerprint) async -> Bool
  ) async throws -> Self {
    let group = MultiThreadedEventLoopGroup.singleton
    let loop = group.next()
    let completion = loop.makePromise(of: Void.self)
    let attempt = try await loop.submit {
      NIOLoopBound(SSHConnectionAttempt(completion: completion), eventLoop: loop)
    }.get()
    let timeout = loop.scheduleTask(in: .seconds(10)) {
      attempt.value.fail(
        SSHConnectionError.connectionFailed("SSH connection timed out (10 seconds)"))
    }
    defer { timeout.cancel() }
    let bootstrap = ClientBootstrap(group: loop)
      .connectTimeout(.seconds(10))
      .channelInitializer { channel in
        guard attempt.value.register(channel) else {
          return channel.eventLoop.makeFailedFuture(
            SSHConnectionError.connectionFailed("SSH connection already ended"))
        }
        return channel.eventLoop.makeCompletedFuture {
          let handler = NIOSSHHandler(
            role: .client(
              .init(
                userAuthDelegate: SSHKeyAuthentication(
                  username: settings.user, privateKey: privateKey),
                serverAuthDelegate: SSHHostKeyAuthentication(decision: hostKeyDecision))),
            allocator: channel.allocator, inboundChildChannelInitializer: nil)
          try channel.pipeline.syncOperations.addHandlers(
            handler, SSHParentHandler(attempt: attempt.value))
        }
      }
    return try await withTaskCancellationHandler {
      bootstrap.connect(host: settings.host, port: settings.port).whenComplete { result in
        switch result {
        case .success(let channel):
          if attempt.value.accept(channel) {
            createAuthenticationProbe(channel: channel, attempt: attempt)
          }
        case .failure(let error):
          attempt.value.fail(error)
        }
      }
      try await completion.futureResult.get()
      return try await loop.submit {
        guard let channel = attempt.value.channel, channel.isActive else {
          throw SSHConnectionError.connectionFailed("SSH connection closed")
        }
        return Self(channel: channel)
      }.get()
    } onCancel: {
      loop.execute { attempt.value.fail(CancellationError()) }
    }
  }

  private static func createAuthenticationProbe(
    channel: any Channel, attempt: NIOLoopBound<SSHConnectionAttempt>
  ) {
    do {
      let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
      let child = channel.eventLoop.makePromise(of: (any Channel).self)
      // TCP 接続だけでは認証完了を保証できないため、session の作成まで待つ。
      handler.createChannel(child, channelType: .session) { child, _ in
        child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      }
      child.futureResult.whenComplete { result in
        switch result {
        case .success(let child):
          child.close(promise: nil)
          attempt.value.succeed()
        case .failure(let error):
          attempt.value.fail(error)
        }
      }
    } catch {
      attempt.value.fail(error)
    }
  }

  // spec の公開 API は終了状態と stdout・stderr を個別に返す。
  // swiftlint:disable:next large_tuple
  func run(_ command: String) async throws -> (exitStatus: Int?, stdout: String, stderr: String) {
    let session = try await makeSession(
      command: command, terminal: nil, onOutput: nil, onClose: nil, timeout: .seconds(15))
    return try await withTaskCancellationHandler {
      let result = try await session.finished.get()
      return (
        result.exitStatus, String(decoding: result.stdout, as: UTF8.self),
        String(decoding: result.stderr, as: UTF8.self)
      )
    } onCancel: {
      session.cancel()
    }
  }

  func openTerminal(
    command: String, columns: Int, rows: Int,
    onOutput: @escaping @Sendable ([UInt8]) -> Void,
    onClose: @escaping @Sendable (Int?) -> Void
  ) async throws -> SSHTerminalChannel {
    let session = try await makeSession(
      command: command, terminal: .init(columns: columns, rows: rows),
      onOutput: onOutput, onClose: onClose, timeout: nil)
    return try await withTaskCancellationHandler {
      SSHTerminalChannel(channel: try await session.ready.get())
    } onCancel: {
      session.cancel()
    }
  }

  func close() {
    channel.close(promise: nil)
  }

  private func makeSession(
    command: String, terminal: SSHTerminalSize?,
    onOutput: (@Sendable ([UInt8]) -> Void)?, onClose: (@Sendable (Int?) -> Void)?,
    timeout: TimeAmount?
  ) async throws -> SSHSession {
    try await channel.eventLoop.submit {
      let state = SSHSessionState(
        loop: channel.eventLoop, command: command, terminal: terminal,
        onOutput: onOutput, onClose: onClose)
      let bound = NIOLoopBound(state, eventLoop: channel.eventLoop)
      let session = SSHSession(
        ready: state.ready.futureResult, finished: state.finished.futureResult, state: bound)
      state.startTimeout(timeout)
      do {
        let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        let child = channel.eventLoop.makePromise(of: (any Channel).self)
        handler.createChannel(child, channelType: .session) { child, _ in
          guard state.accept(child) else {
            return child.eventLoop.makeFailedFuture(
              SSHConnectionError.connectionFailed("SSH session already ended"))
          }
          return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            child.eventLoop.makeCompletedFuture {
              try child.pipeline.syncOperations.addHandler(SSHSessionHandler(state: bound.value))
            }
          }
        }
        child.futureResult.whenFailure { error in bound.value.fail(error) }
      } catch {
        state.fail(error)
      }
      return session
    }.get()
  }
}
