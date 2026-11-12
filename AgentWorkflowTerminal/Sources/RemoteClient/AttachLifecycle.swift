public struct AttachLifecycle: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case idle
    case attaching(String)
    case attached(String)
    case suspended(String)
    case disconnected(String)
  }

  public enum Event: Sendable, Equatable {
    case attachRequested(String)
    case attachSucceeded
    case channelClosed(exitStatus: Int?)
    case enteredBackground
    case enteredForeground
    case reconnectRequested
    case detachRequested
  }

  public enum Effect: Sendable, Equatable {
    case connectAndAttach(String)
    case disconnect
  }

  public private(set) var state: State = .idle

  public init() {}

  public mutating func handle(_ event: Event) -> [Effect] {
    switch (state, event) {
    case (.idle, .attachRequested(let name)):
      state = .attaching(name)
      return [.connectAndAttach(name)]
    case (.attaching(let name), .attachSucceeded):
      state = .attached(name)
    case (.attaching(let name), .channelClosed(let status)),
      (.attached(let name), .channelClosed(let status)):
      // #806 計測2: detach や session 終了では exit-status が届き、回線断では届かない。
      state = status == nil ? .disconnected(name) : .idle
    case (.attaching(let name), .enteredBackground), (.attached(let name), .enteredBackground):
      state = .suspended(name)
      return [.disconnect]
    case (.suspended(let name), .enteredForeground), (.disconnected(let name), .reconnectRequested):
      state = .attaching(name)
      return [.connectAndAttach(name)]
    case (.disconnected(let name), .enteredBackground):
      state = .suspended(name)
    case (.attaching, .detachRequested), (.attached, .detachRequested),
      (.disconnected, .detachRequested):
      state = .idle
      return [.disconnect]
    case (.suspended, .detachRequested):
      state = .idle
    default:
      break
    }
    return []
  }
}
