import NIOCore
import NIOSSH

struct SSHTerminalSize: Sendable {
  let columns: Int
  let rows: Int
}

struct SSHCommandResult: Sendable {
  let exitStatus: Int?
  let stdout: [UInt8]
  let stderr: [UInt8]
}

struct SSHSession: Sendable {
  let ready: EventLoopFuture<any Channel>
  let finished: EventLoopFuture<SSHCommandResult>
  let state: NIOLoopBound<SSHSessionState>

  func cancel() {
    state.eventLoop.execute { state.value.fail(CancellationError()) }
  }
}

final class SSHSessionState {
  let ready: EventLoopPromise<any Channel>
  let finished: EventLoopPromise<SSHCommandResult>
  private let command: String
  private let terminal: SSHTerminalSize?
  private let onOutput: (@Sendable ([UInt8]) -> Void)?
  private let onClose: (@Sendable (Int?) -> Void)?
  private var channel: (any Channel)?
  private var timeout: Scheduled<Void>?
  private var started = false
  private var awaitingPTY = false
  private var accepted = false
  private var ended = false
  private var closed = false
  private var exitStatus: Int?
  private var stdout: [UInt8] = []
  private var stderr: [UInt8] = []

  init(
    loop: any EventLoop, command: String, terminal: SSHTerminalSize?,
    onOutput: (@Sendable ([UInt8]) -> Void)?, onClose: (@Sendable (Int?) -> Void)?
  ) {
    ready = loop.makePromise(of: (any Channel).self)
    finished = loop.makePromise(of: SSHCommandResult.self)
    self.command = command
    self.terminal = terminal
    self.onOutput = onOutput
    self.onClose = onClose
  }

  func startTimeout(_ duration: TimeAmount?) {
    guard let duration else { return }
    let bound = NIOLoopBound(self, eventLoop: ready.futureResult.eventLoop)
    timeout = ready.futureResult.eventLoop.scheduleTask(in: duration) {
      bound.value.fail(SSHConnectionError.connectionFailed("SSH command timed out (15 seconds)"))
    }
  }

  func accept(_ channel: any Channel) -> Bool {
    guard !ended else {
      channel.close(promise: nil)
      return false
    }
    self.channel = channel
    let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
    // open が拒否された子には channelInactive が来ない場合もある。
    channel.closeFuture.whenComplete { _ in bound.value.channelClosed() }
    return true
  }

  func start(context: ChannelHandlerContext) {
    guard !started, !ended else { return }
    started = true
    if let terminal {
      awaitingPTY = true
      send(
        SSHChannelRequestEvent.PseudoTerminalRequest(
          wantReply: true, term: "xterm-256color",
          terminalCharacterWidth: max(1, terminal.columns),
          terminalRowHeight: max(1, terminal.rows),
          terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:])),
        context: context)
    } else {
      sendExec(context: context)
    }
  }

  func success(context: ChannelHandlerContext) {
    guard !ended, !accepted else { return }
    if awaitingPTY {
      awaitingPTY = false
      sendExec(context: context)
    } else {
      accepted = true
      ready.succeed(context.channel)
    }
  }

  func receive(_ data: SSHChannelData) {
    guard !ended, case .byteBuffer(let buffer) = data.data else { return }
    let bytes = Array(buffer.readableBytesView)
    if let onOutput {
      if data.type == .channel || data.type == .stdErr { onOutput(bytes) }
    } else if data.type == .stdErr {
      stderr.append(contentsOf: bytes)
    } else if data.type == .channel {
      stdout.append(contentsOf: bytes)
    }
  }

  func recordExitStatus(_ status: Int) {
    exitStatus = status
  }

  func channelClosed() {
    guard !closed else { return }
    closed = true
    timeout?.cancel()
    timeout = nil
    if !ended {
      if accepted {
        ended = true
        finished.succeed(.init(exitStatus: exitStatus, stdout: stdout, stderr: stderr))
      } else {
        fail(SSHConnectionError.connectionFailed("SSH session closed before exec was accepted"))
      }
    }
    if accepted { onClose?(exitStatus) }
  }

  func fail(_ error: any Error) {
    guard !ended else { return }
    ended = true
    timeout?.cancel()
    timeout = nil
    let failure = SSHConnectionError.wrapping(error)
    if !accepted { ready.fail(failure) }
    finished.fail(failure)
    channel?.close(promise: nil)
  }

  private func sendExec(context: ChannelHandlerContext) {
    send(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), context: context)
  }

  private func send<Event>(_ event: Event, context: ChannelHandlerContext) {
    let promise = context.eventLoop.makePromise(of: Void.self)
    let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
    promise.futureResult.whenFailure { error in bound.value.fail(error) }
    context.triggerUserOutboundEvent(event, promise: promise)
  }
}

final class SSHSessionHandler: ChannelInboundHandler {
  typealias InboundIn = SSHChannelData
  private let state: SSHSessionState

  init(state: SSHSessionState) {
    self.state = state
  }

  func handlerAdded(context: ChannelHandlerContext) {
    if context.channel.isActive { state.start(context: context) }
  }

  func channelActive(context: ChannelHandlerContext) {
    state.start(context: context)
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    state.receive(unwrapInboundIn(data))
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelSuccessEvent:
      state.success(context: context)
    case is ChannelFailureEvent:
      state.fail(SSHConnectionError.connectionFailed("SSH channel request rejected"))
    case let status as SSHChannelRequestEvent.ExitStatus:
      state.recordExitStatus(status.exitStatus)
    default:
      context.fireUserInboundEventTriggered(event)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    state.fail(error)
  }

  func channelInactive(context: ChannelHandlerContext) {
    state.channelClosed()
    context.fireChannelInactive()
  }
}
