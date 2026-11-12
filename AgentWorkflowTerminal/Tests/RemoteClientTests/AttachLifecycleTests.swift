import RemoteClient
import Testing

@Suite("AttachLifecycle — 設計書 §20.6・§20.7、spec 2e")
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
    let generation: Int
  }

  private static var transitions: [Transition] {
    let name = Self.name
    var rows: [Transition] = [
      .init(
        initial: .idle, event: .attachRequested(name), expected: .attaching(name),
        effects: [.connectAndAttach(name, generation: 1)], generation: 1),
      .init(
        initial: .attaching(name), event: .attachSucceeded(generation: 1),
        expected: .attached(name), effects: [], generation: 1),
      .init(
        initial: .suspended(name), event: .attachSucceeded(generation: 1),
        expected: .suspended(name), effects: [.disconnect(generation: 1)], generation: 1),
      .init(
        initial: .suspended(name), event: .enteredForeground, expected: .attaching(name),
        effects: [.connectAndAttach(name, generation: 2)], generation: 2),
      .init(
        initial: .disconnected(name), event: .reconnectRequested, expected: .attaching(name),
        effects: [.connectAndAttach(name, generation: 2)], generation: 2),
      .init(
        initial: .disconnected(name), event: .enteredBackground, expected: .suspended(name),
        effects: [], generation: 1),
      .init(
        initial: .suspended(name), event: .detachRequested, expected: .idle,
        effects: [], generation: 1),
    ]
    for state: State in [.attaching(name), .attached(name)] {
      rows.append(
        .init(
          initial: state, event: .enteredBackground, expected: .suspended(name),
          effects: [.disconnect(generation: 1)], generation: 1))
      for retryable in [true, false] {
        rows.append(
          .init(
            initial: state, event: .attachFailed(generation: 1, retryable: retryable),
            expected: retryable ? .disconnected(name) : .idle, effects: [], generation: 1))
      }
      for status: Int? in [nil, 0, 1, 127] {
        rows.append(
          .init(
            initial: state, event: .channelClosed(generation: 1, exitStatus: status),
            expected: status == nil ? .disconnected(name) : .idle, effects: [], generation: 1))
      }
    }
    for state: State in [.attaching(name), .attached(name), .disconnected(name)] {
      rows.append(
        .init(
          initial: state, event: .detachRequested, expected: .idle,
          effects: [.disconnect(generation: 1)], generation: 1))
    }
    return rows
  }

  private static var ignoredTransitions: [Transition] {
    let ignored: [(State, [Event])] = [
      (
        .idle,
        [
          .attachFailed(generation: 0, retryable: true),
          .attachFailed(generation: 0, retryable: false),
          .channelClosed(generation: 0, exitStatus: nil),
          .channelClosed(generation: 0, exitStatus: 1), .enteredBackground, .enteredForeground,
          .reconnectRequested, .detachRequested,
        ]
      ),
      (.attaching(name), [.attachRequested("other"), .enteredForeground, .reconnectRequested]),
      (
        .attached(name),
        [
          .attachRequested("other"), .attachSucceeded(generation: 1),
          .enteredForeground, .reconnectRequested,
        ]
      ),
      (
        .suspended(name),
        [
          .attachRequested("other"), .enteredBackground, .reconnectRequested,
          .attachFailed(generation: 1, retryable: true),
          .attachFailed(generation: 1, retryable: false),
          .channelClosed(generation: 1, exitStatus: nil),
          .channelClosed(generation: 1, exitStatus: 1),
        ]
      ),
      (
        .disconnected(name),
        [
          .attachRequested("other"), .attachSucceeded(generation: 1),
          .attachFailed(generation: 1, retryable: true),
          .attachFailed(generation: 1, retryable: false),
          .channelClosed(generation: 1, exitStatus: nil),
          .channelClosed(generation: 1, exitStatus: 1),
          .enteredForeground,
        ]
      ),
    ]
    return ignored.flatMap { state, events in
      let generation = state == .idle ? 0 : 1
      return events.map {
        Transition(
          initial: state, event: $0, expected: state, effects: [], generation: generation)
      }
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
      _ = lifecycle.handle(.attachSucceeded(generation: 1))
    case .suspended(let name):
      _ = lifecycle.handle(.attachRequested(name))
      _ = lifecycle.handle(.enteredBackground)
    case .disconnected(let name):
      _ = lifecycle.handle(.attachRequested(name))
      _ = lifecycle.handle(.channelClosed(generation: 1, exitStatus: nil))
    }
    try #require(lifecycle.state == state)
    return lifecycle
  }

  @Test("初期状態は idle、世代は0")
  func initialState() {
    let lifecycle = AttachLifecycle()
    #expect(lifecycle.state == .idle)
    #expect(lifecycle.generation == 0)
  }

  @Test("表の全遷移と接続開始時だけの世代更新", arguments: transitions + ignoredTransitions)
  func appliesTransition(row: Transition) throws {
    var lifecycle = try lifecycle(in: row.initial)
    #expect(lifecycle.handle(row.event) == row.effects)
    #expect(lifecycle.state == row.expected)
    #expect(lifecycle.generation == row.generation)
  }

  @Test(
    "世代の違う成功は閉じ、失敗と切断は全状態で無視する",
    arguments: [
      AttachLifecycle.State.idle, .attaching(name), .attached(name), .suspended(name),
      .disconnected(name),
    ])
  func obsoleteEvents(state: AttachLifecycle.State) throws {
    let initial = try lifecycle(in: state)
    let current = state == .idle ? 0 : 1
    for generation in [current - 1, current + 1] {
      for event: Event in [
        .attachSucceeded(generation: generation),
        .attachFailed(generation: generation, retryable: true),
        .attachFailed(generation: generation, retryable: false),
        .channelClosed(generation: generation, exitStatus: nil),
        .channelClosed(generation: generation, exitStatus: 1),
      ] {
        var lifecycle = initial
        let expected: [Effect]
        if case .attachSucceeded = event {
          expected = [.disconnect(generation: generation)]
        } else {
          expected = []
        }
        #expect(lifecycle.handle(event) == expected)
        #expect(lifecycle.state == state)
        #expect(lifecycle.generation == current)
      }
    }
  }

  @Test(
    "前景で接続開始後に古い channelClosed が届いても新しい接続は attached になる",
    arguments: [nil, 1] as [Int?])
  func delayedClosureAfterForeground(status: Int?) {
    var lifecycle = AttachLifecycle()
    #expect(lifecycle.handle(.attachRequested("計測")) == [.connectAndAttach("計測", generation: 1)])
    #expect(lifecycle.handle(.attachSucceeded(generation: 1)).isEmpty)
    #expect(lifecycle.handle(.enteredBackground) == [.disconnect(generation: 1)])
    #expect(lifecycle.handle(.enteredForeground) == [.connectAndAttach("計測", generation: 2)])
    #expect(lifecycle.handle(.channelClosed(generation: 1, exitStatus: status)).isEmpty)
    #expect(lifecycle.state == .attaching("計測"))
    #expect(lifecycle.handle(.attachSucceeded(generation: 2)).isEmpty)
    #expect(lifecycle.state == .attached("計測"))
    #expect(lifecycle.handle(.detachRequested) == [.disconnect(generation: 2)])
    #expect(lifecycle.state == .idle)
    #expect(lifecycle.generation == 2)
  }

  @Test("detach 後の idle で遅れて成功した同じ世代の接続を閉じる")
  func delayedSuccessAfterDetach() {
    var lifecycle = AttachLifecycle()
    #expect(
      lifecycle.handle(.attachRequested(Self.name)) == [.connectAndAttach(Self.name, generation: 1)]
    )
    #expect(lifecycle.handle(.detachRequested) == [.disconnect(generation: 1)])
    #expect(lifecycle.state == .idle)
    #expect(lifecycle.generation == 1)
    #expect(lifecycle.handle(.attachSucceeded(generation: 1)) == [.disconnect(generation: 1)])
    #expect(lifecycle.state == .idle)
    #expect(lifecycle.generation == 1)
  }

  @Test("裏で遅れて成功した接続を閉じ、同じ名前へ新しい世代で戻る")
  func delayedSuccessWhileSuspended() {
    var lifecycle = AttachLifecycle()
    let name = #"bs\\x"#
    #expect(lifecycle.handle(.attachRequested(name)) == [.connectAndAttach(name, generation: 1)])
    #expect(lifecycle.handle(.enteredBackground) == [.disconnect(generation: 1)])
    #expect(lifecycle.handle(.attachSucceeded(generation: 1)) == [.disconnect(generation: 1)])
    #expect(lifecycle.state == .suspended(name))
    #expect(lifecycle.handle(.channelClosed(generation: 1, exitStatus: 1)).isEmpty)
    #expect(lifecycle.handle(.enteredForeground) == [.connectAndAttach(name, generation: 2)])
    #expect(lifecycle.handle(.attachSucceeded(generation: 1)) == [.disconnect(generation: 1)])
    #expect(lifecycle.state == .attaching(name))
    #expect(lifecycle.handle(.attachSucceeded(generation: 2)).isEmpty)
    #expect(lifecycle.state == .attached(name))
    #expect(lifecycle.generation == 2)
  }

  @Test("再接続と別 session の選択でも世代は単調に増える")
  func reconnectAndSelectAnotherSession() {
    var lifecycle = AttachLifecycle()
    _ = lifecycle.handle(.attachRequested(Self.name))
    _ = lifecycle.handle(.attachFailed(generation: 1, retryable: true))
    #expect(lifecycle.state == .disconnected(Self.name))
    #expect(lifecycle.handle(.reconnectRequested) == [.connectAndAttach(Self.name, generation: 2)])
    _ = lifecycle.handle(.detachRequested)
    #expect(lifecycle.handle(.enteredForeground).isEmpty)
    #expect(
      lifecycle.handle(.attachRequested("sp 'q")) == [.connectAndAttach("sp 'q", generation: 3)])
    #expect(lifecycle.generation == 3)
  }
}
