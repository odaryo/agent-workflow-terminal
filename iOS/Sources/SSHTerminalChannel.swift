import NIOCore
import NIOSSH

struct SSHTerminalChannel: Sendable {
  private let channel: any Channel

  init(channel: any Channel) {
    self.channel = channel
  }

  func write(_ bytes: [UInt8]) {
    channel.eventLoop.execute {
      guard channel.isActive else { return }
      var buffer = channel.allocator.buffer(capacity: bytes.count)
      buffer.writeBytes(bytes)
      channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }
  }

  func resize(columns: Int, rows: Int) {
    channel.pipeline.triggerUserOutboundEvent(
      SSHChannelRequestEvent.WindowChangeRequest(
        terminalCharacterWidth: max(1, columns), terminalRowHeight: max(1, rows),
        terminalPixelWidth: 0, terminalPixelHeight: 0), promise: nil)
  }

  func close() {
    channel.close(promise: nil)
  }
}
