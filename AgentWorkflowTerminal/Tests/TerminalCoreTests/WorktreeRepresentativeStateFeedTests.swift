import Foundation
import TerminalCore
import Testing
import os

@Suite("worktree表示用代表状態の配信 (設計書 §12.2)")
struct WorktreeRepresentativeStateFeedTests {
  @Test("初回観測を即時に配信する")
  func firstObservationIsImmediate() async throws {
    let context = Context()
    defer { context.cancel() }
    context.send([pane("%0", .working)])

    let output = try await context.output(at: 0)
    #expect(output.state == state(.working))
    #expect(output.at == context.start)
  }

  @Test("Needs Attention と Ready for Review は保持せず配信する")
  func urgentStatesAreImmediate() async throws {
    let context = Context()
    defer { context.cancel() }
    context.send([pane("%0", .working)])
    _ = try await context.output(at: 0)

    context.advance(by: .seconds(1))
    context.send([pane("%1", .permission)])
    #expect(try await context.output(at: 1).state == state(.permission, paneID: "%1"))

    context.advance(by: .seconds(1))
    context.send([pane("%2", .completed)])
    #expect(try await context.output(at: 2).state == state(.completed, paneID: "%2"))
  }

  @Test("入力終了後も Working から Idle への保持を満了時刻に反映する")
  func idleExpiresAfterInputEnds() async throws {
    let context = Context(holdDuration: .seconds(9))
    defer { context.cancel() }
    context.send([pane("%0", .working)])
    _ = try await context.output(at: 0)

    context.advance(by: .seconds(1))
    context.send([pane("%0", .idle)])
    context.finishInput()
    try await context.waitForSleeper("idle timer")
    #expect(await context.outputs.count == 1)

    context.advance(by: .seconds(9))
    let output = try await context.output(at: 1, label: "idle output")
    #expect(output.state == state(.idle))
    #expect(output.at == context.start.advanced(by: .seconds(10)))
    try await context.waitForCompletion("idle completion")
  }

  @Test("Idle と Unknown の追加観測は最初の保持起点を動かさない")
  func pendingObservationsKeepOriginalDeadline() async throws {
    let context = Context(holdDuration: .seconds(9))
    defer { context.cancel() }
    context.send([pane("%0", .working)])
    _ = try await context.output(at: 0)

    context.advance(by: .seconds(1))
    context.send([pane("%0", .idle)])
    try await context.waitForSleeper("original timer")
    context.advance(by: .seconds(3))
    context.send([pane("%0", .unknown)])
    await context.settle()
    #expect(await context.outputs.count == 1)

    context.advance(by: .seconds(6))
    let output = try await context.output(at: 1, label: "unknown output")
    #expect(output.state == state(.unknown))
    #expect(output.at == context.start.advanced(by: .seconds(10)))
  }

  @Test("保持中に表示中または保持対象外の分類が来ると即時反映する")
  func cancellingObservationsAreImmediate() async throws {
    let context = Context()
    defer { context.cancel() }
    context.send([pane("%0", .working)])
    _ = try await context.output(at: 0)
    context.send([pane("%0", .idle)])
    try await context.waitForSleeper()

    context.send([pane("%1", .working)])
    #expect(try await context.output(at: 1).state == state(.working, paneID: "%1"))

    context.send([pane("%1", .idle)])
    try await context.waitForSleeper()
    context.send([pane("%2", .question)])
    #expect(try await context.output(at: 2).state == state(.question, paneID: "%2"))
  }

  @Test("同じ表示値は重複して配信しない")
  func duplicateDisplayValuesAreSuppressed() async throws {
    let context = Context()
    defer { context.cancel() }
    let working = [pane("%0", .working)]
    context.send(working)
    _ = try await context.output(at: 0)
    context.send(working)
    context.send(working)
    await context.settle()

    #expect(await context.outputs.count == 1)
  }

  @Test("pane が0件なら nil を配信する")
  func noPanesYieldsNil() async throws {
    let context = Context()
    defer { context.cancel() }
    context.send([])

    #expect(try await context.output(at: 0).state == nil)
  }

  @Test("出力 stream の破棄で待機中のタイマーを終了する")
  func terminationCancelsTimer() async throws {
    let clock = TestTimeSource()
    let input = AsyncStream<[PaneAgentState]>.makeStream()
    let output = WorktreeRepresentativeStateFeed(
      holdDuration: .seconds(9)
    ).states(from: input.stream, timeSource: clock)
    let consumer = Task {
      for await _ in output {}
    }
    input.continuation.yield([pane("%0", .working)])
    input.continuation.yield([pane("%0", .idle)])
    try await waitUntil { clock.sleepCount == 1 }

    consumer.cancel()
    try await waitUntil { clock.sleepCount == 0 }
  }

  private struct Context {
    let start: ContinuousClock.Instant
    let clock: TestTimeSource
    let input: AsyncStream<[PaneAgentState]>.Continuation
    let outputs: OutputRecorder
    let consumer: Task<Void, Never>

    init(holdDuration: Duration = .seconds(9)) {
      let clock = TestTimeSource()
      let input = AsyncStream<[PaneAgentState]>.makeStream()
      let outputs = OutputRecorder(clock: clock)
      let stream = WorktreeRepresentativeStateFeed(holdDuration: holdDuration).states(
        from: input.stream, timeSource: clock
      )
      self.start = clock.now
      self.clock = clock
      self.input = input.continuation
      self.outputs = outputs
      self.consumer = Task {
        for await value in stream {
          await outputs.append(value)
        }
        await outputs.complete()
      }
    }

    func send(_ panes: [PaneAgentState]) {
      input.yield(panes)
    }

    func finishInput() {
      input.finish()
    }

    func cancel() {
      consumer.cancel()
      input.finish()
    }

    func advance(by duration: Duration) {
      clock.advance(by: duration)
    }

    func output(at index: Int, label: String = "output") async throws -> TimedOutput {
      try await waitUntil(label) { await outputs.count > index }
      return try #require(await outputs.value(at: index))
    }

    func waitForSleeper(_ label: String = "timer") async throws {
      try await waitUntil(label) { clock.sleepCount == 1 }
    }

    func waitForCompletion(_ label: String = "completion") async throws {
      try await waitUntil(label) { await outputs.isComplete }
    }

    func settle() async {
      for _ in 0..<20 { await Task.yield() }
    }
  }

  private actor OutputRecorder {
    private let clock: TestTimeSource
    private var recorded: [TimedOutput] = []
    private(set) var isComplete = false

    init(clock: TestTimeSource) {
      self.clock = clock
    }

    var count: Int { recorded.count }

    func append(_ state: WorktreeRepresentativeState?) {
      recorded.append(TimedOutput(state: state, at: clock.now))
    }

    func complete() {
      isComplete = true
    }

    func value(at index: Int) -> TimedOutput? {
      recorded.indices.contains(index) ? recorded[index] : nil
    }
  }

  private struct TimedOutput: Sendable {
    let state: WorktreeRepresentativeState?
    let at: ContinuousClock.Instant
  }

  private func pane(_ id: String, _ state: AgentState) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id), state: state,
      lastUpdatedAt: Date(timeIntervalSince1970: 0)
    )
  }

  private func state(
    _ agentState: AgentState, paneID: String = "%0"
  ) -> WorktreeRepresentativeState {
    WorktreeRepresentativeState(
      category: agentState.worktreeCategory,
      state: agentState,
      paneID: PaneID(rawValue: paneID)
    )
  }
}

private struct TestTimeSource: ContinuousTimeSource {
  private struct State {
    var now = ContinuousClock().now
    var sleepers: [UUID: Sleeper] = [:]
    var cancelled: Set<UUID> = []
  }

  private struct Sleeper {
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let storage = OSAllocatedUnfairLock(initialState: State())

  var now: ContinuousClock.Instant {
    storage.withLock { $0.now }
  }

  var sleepCount: Int {
    storage.withLock { $0.sleepers.count }
  }

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = storage.withLock { state in
          if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
          if state.now >= deadline { return .success(()) }
          state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let sleeper: Sleeper? = storage.withLock { state in
        if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
        state.cancelled.insert(id)
        return nil
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let continuations = storage.withLock { state in
      state.now = state.now.advanced(by: duration)
      let ready = state.sleepers.filter { $0.value.deadline <= state.now }
      for id in ready.keys { state.sleepers.removeValue(forKey: id) }
      return ready.values.map(\.continuation)
    }
    for continuation in continuations { continuation.resume() }
  }
}

private struct TestTimeout: Error {
  let label: String
}

private func waitUntil(
  _ label: String = "condition",
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<1_000 {
    if await condition() { return }
    await Task.yield()
  }
  throw TestTimeout(label: label)
}
