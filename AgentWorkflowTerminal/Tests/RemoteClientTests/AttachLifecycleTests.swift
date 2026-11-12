import RemoteClient
import Testing

@Suite("AttachLifecycle — 設計書 §20.6・§20.7")
struct AttachLifecycleTests {
  private typealias State = AttachLifecycle.State
  private typealias Event = AttachLifecycle.Event
  private typealias Effect = AttachLifecycle.Effect

  private static let name = "a|b  c "

  struct Transition: Sendable {
    let initial: AttachLifecycle.State
    let event: AttachLifecycle.Event
    let expected: AttachLifecycle.State
    let effects: [AttachLifecycle.Effect]
  }

  private static var transitions: [Transition] {
    let name = Self.name
    return [
      Transition(
        initial: .idle, event: .attachRequested(name),
        expected: .attaching(name), effects: [.connectAndAttach(name)]),
      Transition(
        initial: .attaching(name), event: .attachSucceeded,
        expected: .attached(name), effects: []),
      Transition(
        initial: .attaching(name), event: .enteredBackground,
        expected: .suspended(name), effects: [.disconnect]),
      Transition(
        initial: .attached(name), event: .enteredBackground,
        expected: .suspended(name), effects: [.disconnect]),
      Transition(
        initial: .suspended(name), event: .enteredForeground,
        expected: .attaching(name), effects: [.connectAndAttach(name)]),
      Transition(
        initial: .disconnected(name), event: .reconnectRequested,
        expected: .attaching(name), effects: [.connectAndAttach(name)]),
      Transition(
        initial: .disconnected(name), event: .enteredBackground,
        expected: .suspended(name), effects: []),
      Transition(
        initial: .attaching(name), event: .detachRequested,
        expected: .idle, effects: [.disconnect]),
      Transition(
        initial: .attached(name), event: .detachRequested,
        expected: .idle, effects: [.disconnect]),
      Transition(
        initial: .disconnected(name), event: .detachRequested,
        expected: .idle, effects: [.disconnect]),
      Transition(
        initial: .suspended(name), event: .detachRequested,
        expected: .idle, effects: []),
    ]
  }

  private static var closureTransitions: [Transition] {
    var transitions: [Transition] = []
    for status: Int? in [nil, 0, 1, 127] {
      for state: State in [.attaching(name), .attached(name)] {
        transitions.append(
          Transition(
            initial: state, event: .channelClosed(exitStatus: status),
            expected: status == nil ? .disconnected(name) : .idle, effects: []))
      }
      transitions.append(
        Transition(
          initial: .suspended(name), event: .channelClosed(exitStatus: status),
          expected: .suspended(name), effects: []))
    }
    return transitions
  }

  private static var ignoredTransitions: [Transition] {
    let allEvents: [Event] = [
      .attachRequested("sp 'q"), .attachSucceeded, .channelClosed(exitStatus: nil),
      .channelClosed(exitStatus: 1), .enteredBackground, .enteredForeground,
      .reconnectRequested, .detachRequested,
    ]
    let ignored: [(State, [Event])] = [
      (
        .idle,
        allEvents.filter {
          if case .attachRequested = $0 { return false }
          return true
        }
      ),
      (.attaching(name), [.attachRequested("sp 'q"), .enteredForeground, .reconnectRequested]),
      (
        .attached(name),
        [
          .attachRequested("sp 'q"), .attachSucceeded, .enteredForeground, .reconnectRequested,
        ]
      ),
      (
        .suspended(name),
        [
          .attachRequested("sp 'q"), .attachSucceeded, .enteredBackground, .reconnectRequested,
        ]
      ),
      (
        .disconnected(name),
        [
          .attachRequested("sp 'q"), .attachSucceeded, .channelClosed(exitStatus: nil),
          .channelClosed(exitStatus: 1), .enteredForeground,
        ]
      ),
    ]
    return ignored.flatMap { state, events in
      events.map { Transition(initial: state, event: $0, expected: state, effects: []) }
    }
  }

  private func lifecycle(in state: State) throws -> AttachLifecycle {
    var lifecycle = AttachLifecycle()
    switch state {
    case .idle:
      break
    case .attaching(let name):
      _ = lifecycle.handle(.attachRequested(name))
    case .attached(let name):
      _ = lifecycle.handle(.attachRequested(name))
      _ = lifecycle.handle(.attachSucceeded)
    case .suspended(let name):
      _ = lifecycle.handle(.attachRequested(name))
      _ = lifecycle.handle(.enteredBackground)
    case .disconnected(let name):
      _ = lifecycle.handle(.attachRequested(name))
      _ = lifecycle.handle(.channelClosed(exitStatus: nil))
    }
    try #require(lifecycle.state == state)
    return lifecycle
  }

  @Test("初期状態は idle")
  func initiallyIdle() {
    #expect(AttachLifecycle().state == .idle)
  }

  @Test("表の接続・背景化・再接続・detach", arguments: transitions)
  func specifiedTransitions(transition: Transition) throws {
    var lifecycle = try lifecycle(in: transition.initial)
    #expect(lifecycle.handle(transition.event) == transition.effects)
    #expect(lifecycle.state == transition.expected)
  }

  @Test(
    "exit-status の有無で終了と通信切断を区別し、suspended では無視する",
    arguments: closureTransitions)
  func channelClosure(transition: Transition) throws {
    var lifecycle = try lifecycle(in: transition.initial)
    #expect(lifecycle.handle(transition.event) == transition.effects)
    #expect(lifecycle.state == transition.expected)
  }

  @Test("表に無いイベントは状態を変えず副作用も出さない", arguments: ignoredTransitions)
  func unspecifiedTransitions(transition: Transition) throws {
    var lifecycle = try lifecycle(in: transition.initial)
    #expect(lifecycle.handle(transition.event).isEmpty)
    #expect(lifecycle.state == transition.initial)
  }

  @Test("背景で disconnect した後の channelClosed では前景復帰先を失わない")
  func backgroundDisconnectAndForeground() {
    var lifecycle = AttachLifecycle()
    #expect(lifecycle.handle(.attachRequested("計測")) == [.connectAndAttach("計測")])
    #expect(lifecycle.handle(.attachSucceeded).isEmpty)
    #expect(lifecycle.handle(.enteredBackground) == [.disconnect])
    #expect(lifecycle.handle(.channelClosed(exitStatus: 1)).isEmpty)
    #expect(lifecycle.state == .suspended("計測"))
    #expect(lifecycle.handle(.enteredForeground) == [.connectAndAttach("計測")])
    #expect(lifecycle.state == .attaching("計測"))
    #expect(lifecycle.handle(.attachSucceeded).isEmpty)
    #expect(lifecycle.state == .attached("計測"))
  }

  @Test("通信切断後に背景化した場合も同じ正式名に再接続する")
  func disconnectedThenBackground() {
    var lifecycle = AttachLifecycle()
    let name = #"bs\\x"#
    #expect(lifecycle.handle(.attachRequested(name)) == [.connectAndAttach(name)])
    #expect(lifecycle.handle(.attachSucceeded).isEmpty)
    #expect(lifecycle.handle(.channelClosed(exitStatus: nil)).isEmpty)
    #expect(lifecycle.state == .disconnected(name))
    #expect(lifecycle.handle(.enteredBackground).isEmpty)
    #expect(lifecycle.handle(.channelClosed(exitStatus: nil)).isEmpty)
    #expect(lifecycle.handle(.enteredForeground) == [.connectAndAttach(name)])
    #expect(lifecycle.state == .attaching(name))
  }

  @Test("detach 後は前景イベントで再接続せず、別 session を指定できる")
  func detachAndSelectAnotherSession() {
    var lifecycle = AttachLifecycle()
    #expect(lifecycle.handle(.attachRequested(Self.name)) == [.connectAndAttach(Self.name)])
    #expect(lifecycle.handle(.enteredBackground) == [.disconnect])
    #expect(lifecycle.handle(.detachRequested).isEmpty)
    #expect(lifecycle.handle(.enteredForeground).isEmpty)
    #expect(lifecycle.state == .idle)
    #expect(lifecycle.handle(.attachRequested("sp 'q")) == [.connectAndAttach("sp 'q")])
    #expect(lifecycle.state == .attaching("sp 'q"))
  }
}
