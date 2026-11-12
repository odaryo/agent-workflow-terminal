import CryptoKit
import NIOCore
import NIOSSH
import RemoteClient

final class SSHKeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
  private let username: String
  private let key: NIOSSHPrivateKey
  private var offered = false

  init(username: String, privateKey: Curve25519.Signing.PrivateKey) {
    self.username = username
    key = NIOSSHPrivateKey(ed25519Key: privateKey)
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard !offered, availableMethods.contains(.publicKey) else {
      nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
      return
    }
    offered = true
    nextChallengePromise.succeed(
      .init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
  }
}

struct SSHHostKeyAuthentication: NIOSSHClientServerAuthenticationDelegate {
  let decision: @Sendable (SSHHostKeyFingerprint) async -> Bool
  let attempt: NIOLoopBound<SSHConnectionAttempt>

  func validateHostKey(
    hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
  ) {
    guard
      let fingerprint = SSHHostKeyFingerprint(
        openSSHPublicKeyLine: String(openSSHPublicKey: hostKey))
    else {
      validationCompletePromise.fail(SSHConnectionError.connectionFailed("Invalid SSH host key"))
      return
    }
    attempt.value.stopTimeout()
    let decision = decision
    let attempt = attempt
    Task {
      let approved = await decision(fingerprint)
      attempt.eventLoop.execute {
        attempt.value.startTimeout()
        if approved {
          validationCompletePromise.succeed(())
        } else {
          validationCompletePromise.fail(SSHConnectionError.hostKeyRejected(fingerprint))
        }
      }
    }
  }
}

final class SSHConnectionAttempt {
  let completion: EventLoopPromise<Void>
  var channel: (any Channel)?
  private var finished = false
  private var firstError: SSHConnectionError?
  private var candidates: [any Channel] = []
  private var candidateErrors: [ObjectIdentifier: SSHConnectionError] = [:]
  private var timeout: Scheduled<Void>?

  init(completion: EventLoopPromise<Void>) {
    self.completion = completion
  }

  func startTimeout() {
    guard !finished else { return }
    stopTimeout()
    let loop = completion.futureResult.eventLoop
    let bound = NIOLoopBound(self, eventLoop: loop)
    timeout = loop.scheduleTask(in: .seconds(10)) {
      bound.value.fail(
        SSHConnectionError.connectionFailed("SSH connection timed out (10 seconds)"))
    }
  }

  func stopTimeout() {
    timeout?.cancel()
    timeout = nil
  }

  func succeed() {
    guard !finished else { return }
    finished = true
    stopTimeout()
    candidates.removeAll()
    candidateErrors.removeAll()
    completion.succeed(())
  }

  func fail(_ error: any Error) {
    guard !finished else { return }
    if firstError == nil { firstError = SSHConnectionError.wrapping(error) }
    finished = true
    stopTimeout()
    completion.fail(firstError ?? SSHConnectionError.wrapping(error))
    for candidate in candidates { candidate.close(promise: nil) }
    candidates.removeAll()
    channel?.close(promise: nil)
  }

  func register(_ channel: any Channel) -> Bool {
    guard !finished else {
      channel.close(promise: nil)
      return false
    }
    candidates.append(channel)
    return true
  }

  func fail(_ error: any Error, from source: any Channel) {
    // Happy Eyeballs の不採用候補の切断は、採用した接続の失敗ではない。
    let identifier = ObjectIdentifier(source)
    if candidateErrors[identifier] == nil {
      candidateErrors[identifier] = SSHConnectionError.wrapping(error)
    }
    guard let channel, channel === source else { return }
    fail(candidateErrors[identifier] ?? SSHConnectionError.wrapping(error))
  }

  func accept(_ channel: any Channel) -> Bool {
    guard !finished else {
      channel.close(promise: nil)
      return false
    }
    self.channel = channel
    if let error = candidateErrors[ObjectIdentifier(channel)] {
      fail(error)
      return false
    }
    return true
  }
}

final class SSHParentHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  private let attempt: SSHConnectionAttempt

  init(attempt: SSHConnectionAttempt) {
    self.attempt = attempt
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    attempt.fail(error, from: context.channel)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    attempt.fail(
      SSHConnectionError.connectionFailed("SSH connection closed"), from: context.channel)
    context.fireChannelInactive()
  }
}
