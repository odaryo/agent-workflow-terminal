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
    case attachSucceeded(generation: Int)
    case attachFailed(generation: Int, retryable: Bool)
    case channelClosed(generation: Int, exitStatus: Int?)
    case enteredBackground
    case enteredForeground
    case reconnectRequested
    case detachRequested
  }

  public enum Effect: Sendable, Equatable {
    case connectAndAttach(String, generation: Int)
    case disconnect(generation: Int)
  }

  public private(set) var state: State = .idle

  public private(set) var generation: Int = 0

  public init() {}

  public mutating func handle(_ event: Event) -> [Effect] {
    switch event {
    case .attachSucceeded(let value):
      guard value == generation else { return [.disconnect(generation: value)] }
      return handleAttachSucceeded()
    case .attachFailed(let value, _) where value != generation,
      .channelClosed(let value, _) where value != generation:
      return []
    default:
      break
    }
    return handleCurrentGeneration(event)
  }

  private mutating func handleCurrentGeneration(_ event: Event) -> [Effect] {
    switch (state, event) {
    case (.idle, .attachRequested(let name)):
      return connectAndAttach(name)
    case (.attaching(let name), .attachFailed(_, let retryable)),
      (.attached(let name), .attachFailed(_, let retryable)):
      // host key の拒否・認証の失敗・session 不在は再接続しても解消しない。
      handleFailure(name: name, retryable: retryable)
    case (.attaching(let name), .channelClosed(_, let status)),
      (.attached(let name), .channelClosed(_, let status)):
      // #806 計測2: detach や session 終了では exit-status が届き、回線断では届かない。
      handleFailure(name: name, retryable: status == nil)
    case (.attaching(let name), .enteredBackground), (.attached(let name), .enteredBackground):
      state = .suspended(name)
      return [.disconnect(generation: generation)]
    case (.suspended(let name), .enteredForeground), (.disconnected(let name), .reconnectRequested):
      return connectAndAttach(name)
    case (.disconnected(let name), .enteredBackground):
      state = .suspended(name)
    case (.attaching, .detachRequested), (.attached, .detachRequested),
      (.disconnected, .detachRequested):
      state = .idle
      return [.disconnect(generation: generation)]
    case (.suspended, .detachRequested):
      state = .idle
    default:
      break
    }
    return []
  }

  private mutating func handleFailure(name: String, retryable: Bool) {
    state = retryable ? .disconnected(name) : .idle
  }

  private mutating func handleAttachSucceeded() -> [Effect] {
    switch state {
    case .attaching(let name):
      state = .attached(name)
    case .suspended:
      return [.disconnect(generation: generation)]
    default:
      break
    }
    return []
  }

  private mutating func connectAndAttach(_ name: String) -> [Effect] {
    generation += 1
    state = .attaching(name)
    return [.connectAndAttach(name, generation: generation)]
  }
}
