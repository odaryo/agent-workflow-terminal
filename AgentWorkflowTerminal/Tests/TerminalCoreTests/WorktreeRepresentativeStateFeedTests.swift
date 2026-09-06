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
    await context.send([pane("%0", .working)])

    let output = try await context.output()
    #expect(output.state == state(.working))
    #expect(output.at == context.start)
  }

  @Test("Needs Attention と Ready for Review は保持せず配信する")
  func urgentStatesAreImmediate() async throws {
    let context = Context()
    defer { context.cancel() }
    await context.send([pane("%0", .working)])
    _ = try await context.output()

    context.advance(by: .seconds(1))
    await context.send([pane("%1", .permission)])
    #expect(try await context.output().state == state(.permission, paneID: "%1"))

    context.advance(by: .seconds(1))
    await context.send([pane("%2", .completed)])
    #expect(try await context.output().state == state(.completed, paneID: "%2"))
  }

  @Test("入力終了後も Working から Idle への保持を満了時刻に反映する")
  func idleExpiresAfterInputEnds() async throws {
    let context = Context(holdDuration: .seconds(9))
    defer { context.cancel() }
    await context.send([pane("%0", .working)])
    _ = try await context.output()

    context.advance(by: .seconds(1))
    await context.send([pane("%0", .idle)])
    context.finishInput()
    await context.waitForSleepCount(1)

    context.advance(by: .seconds(9))
    let output = try await context.output()
    #expect(output.state == state(.idle))
    #expect(output.at == context.start.advanced(by: .seconds(10)))
    await context.expectCompletion()
  }

  @Test("Idle と Unknown の追加観測は最初の保持起点を動かさない")
  func pendingObservationsKeepOriginalDeadline() async throws {
    let context = Context(holdDuration: .seconds(9))
    defer { context.cancel() }
    await context.send([pane("%0", .working)])
    _ = try await context.output()

    context.advance(by: .seconds(1))
    await context.send([pane("%0", .idle)])
    await context.waitForSleepCount(1)
    context.advance(by: .seconds(3))
    await context.send([pane("%0", .unknown)])

    context.advance(by: .seconds(6))
    let output = try await context.output()
    #expect(output.state == state(.unknown))
    #expect(output.at == context.start.advanced(by: .seconds(10)))
  }

  @Test("保持中に表示中または保持対象外の分類が来ると即時反映する")
  func cancellingObservationsAreImmediate() async throws {
    let context = Context()
    defer { context.cancel() }
    await context.send([pane("%0", .working)])
    _ = try await context.output()
    await context.send([pane("%0", .idle)])
    await context.waitForSleepCount(1)

    await context.send([pane("%1", .working)])
    #expect(try await context.output().state == state(.working, paneID: "%1"))

    await context.send([pane("%1", .idle)])
    await context.waitForSleepCount(1)
    await context.send([pane("%2", .question)])
    #expect(try await context.output().state == state(.question, paneID: "%2"))
  }

  @Test("同じ表示値は重複して配信しない")
  func duplicateDisplayValuesAreSuppressed() async throws {
    let context = Context()
    defer { context.cancel() }
    let working = [pane("%0", .working)]
    await context.send(working)
    await context.send(working)
    await context.send(working)
    context.finishInput()

    #expect(try await context.output().state == state(.working))
    await context.expectCompletion()
  }

  @Test("pane が0件なら nil を配信する")
  func noPanesYieldsNil() async throws {
    let context = Context()
    defer { context.cancel() }
    await context.send([])

    #expect(try await context.output().state == nil)
  }

  @Test("出力 stream の破棄で待機中のタイマーを終了する")
  func terminationCancelsTimer() async {
    let context = Context()
    defer { context.finishInput() }
    await context.send([pane("%0", .working)])
    await context.send([pane("%0", .idle)])
    await context.waitForSleepCount(1)

    context.cancelConsumer()

    await context.waitForSleepCount(0)
  }

  @Test("保持中でなければ入力終了時に出力 stream を終了する")
  func inputCompletionFinishesOutput() async throws {
    let context = Context()
    defer { context.cancel() }
    await context.send([pane("%0", .working)])
    context.finishInput()

    #expect(try await context.output().state == state(.working))
    await context.expectCompletion()
  }

  @Test("空の入力列が終了すると値を配信せず出力 stream を終了する")
  func emptyInputFinishesOutputWithoutValue() async {
    let context = Context()
    defer { context.cancel() }
    context.finishInput()

    await context.expectCompletion()
  }

  private struct Context {
    let start: ContinuousClock.Instant
    private let clock: TestTimeSource
    private let input: TestInputSequence
    private let outputs: OutputMailbox
    private let consumer: Task<Void, Never>

    init(holdDuration: Duration = .seconds(9)) {
      let clock = TestTimeSource()
      let input = TestInputSequence()
      let outputs = OutputMailbox()
      let stream = WorktreeRepresentativeStateFeed(
        stabilizer: WorktreeRepresentativeStateStabilizer(holdDuration: holdDuration)
      ).states(from: input, timeSource: clock)
      self.start = clock.now
      self.clock = clock
      self.input = input
      self.outputs = outputs
      self.consumer = Task {
        for await value in stream {
          await outputs.receive(TimedOutput(state: value, at: clock.now))
        }
        await outputs.finish()
      }
    }

    func send(_ panes: [PaneAgentState]) async {
      await input.sendAndWaitUntilProcessed(panes)
    }

    func finishInput() { input.finish() }

    func cancelConsumer() { consumer.cancel() }

    func cancel() {
      consumer.cancel()
      input.finish()
    }

    func advance(by duration: Duration) { clock.advance(by: duration) }

    func waitForSleepCount(_ count: Int) async {
      await clock.waitForSleepCount(count)
    }

    func output() async throws -> TimedOutput {
      try #require(await outputs.next())
    }

    func expectCompletion() async {
      #expect(await outputs.next() == nil)
    }
  }

  private actor OutputMailbox {
    private var queued: [TimedOutput] = []
    private var waiter: CheckedContinuation<TimedOutput?, Never>?
    private var isFinished = false

    func receive(_ output: TimedOutput) {
      if let waiter {
        self.waiter = nil
        waiter.resume(returning: output)
      } else {
        queued.append(output)
      }
    }

    func finish() {
      isFinished = true
      waiter?.resume(returning: nil)
      waiter = nil
    }

    func next() async -> TimedOutput? {
      if !queued.isEmpty { return queued.removeFirst() }
      if isFinished { return nil }
      return await withCheckedContinuation { waiter = $0 }
    }
  }

  private struct TimedOutput: Sendable, Equatable {
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

private struct TestInputSequence: AsyncSequence, Sendable {
  typealias Element = [PaneAgentState]

  struct AsyncIterator: AsyncIteratorProtocol {
    let sequence: TestInputSequence

    mutating func next() async -> Element? { await sequence.next() }
  }

  private struct QueuedElement {
    let value: Element
    let processed: CheckedContinuation<Void, Never>
  }

  private struct NextWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Element?, Never>
  }

  private struct State {
    var queued: [QueuedElement] = []
    var nextWaiter: NextWaiter?
    var lastProcessed: CheckedContinuation<Void, Never>?
    var isFinished = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(sequence: self) }

  func sendAndWaitUntilProcessed(_ value: Element) async {
    await withCheckedContinuation { processed in
      let next = state.withLock { state -> CheckedContinuation<Element?, Never>? in
        if let waiter = state.nextWaiter {
          state.nextWaiter = nil
          state.lastProcessed = processed
          return waiter.continuation
        }
        state.queued.append(QueuedElement(value: value, processed: processed))
        return nil
      }
      next?.resume(returning: value)
    }
  }

  func finish() {
    let continuations = state.withLock { state in
      state.isFinished = true
      let result = (state.lastProcessed, state.nextWaiter?.continuation)
      state.lastProcessed = nil
      state.nextWaiter = nil
      return result
    }
    continuations.0?.resume()
    continuations.1?.resume(returning: nil)
  }

  private func next() async -> Element? {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let result = state.withLock { state -> NextResult in
          let processed = state.lastProcessed
          state.lastProcessed = nil
          if !state.queued.isEmpty {
            let queued = state.queued.removeFirst()
            state.lastProcessed = queued.processed
            return NextResult(processed: processed, value: queued.value, shouldWait: false)
          }
          if state.isFinished {
            return NextResult(processed: processed, value: nil, shouldWait: false)
          }
          state.nextWaiter = NextWaiter(id: id, continuation: continuation)
          return NextResult(processed: processed, value: nil, shouldWait: true)
        }
        result.processed?.resume()
        if !result.shouldWait { continuation.resume(returning: result.value) }
      }
    } onCancel: {
      let continuation = state.withLock { state -> CheckedContinuation<Element?, Never>? in
        guard state.nextWaiter?.id == id else { return nil }
        let continuation = state.nextWaiter?.continuation
        state.nextWaiter = nil
        return continuation
      }
      continuation?.resume(returning: nil)
    }
  }

  private struct NextResult {
    let processed: CheckedContinuation<Void, Never>?
    let value: Element?
    let shouldWait: Bool
  }
}

private struct TestTimeSource: ContinuousTimeSource {
  private struct Sleeper {
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct CountWaiter {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct State {
    var now = ContinuousClock().now
    var sleepers: [UUID: Sleeper] = [:]
    var cancelled: Set<UUID> = []
    var countWaiters: [UUID: CountWaiter] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var now: ContinuousClock.Instant { state.withLock { $0.now } }

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let action = state.withLock { state -> SleepAction in
          if state.cancelled.remove(id) != nil {
            return SleepAction(result: .failure(CancellationError()), countWaiters: [])
          }
          if state.now >= deadline {
            return SleepAction(result: .success(()), countWaiters: [])
          }
          state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return SleepAction(result: nil, countWaiters: takeSatisfiedCountWaiters(state: &state))
        }
        for waiter in action.countWaiters { waiter.resume() }
        if let result = action.result { continuation.resume(with: result) }
      }
    } onCancel: {
      let action = state.withLock { state -> CancellationAction in
        guard let sleeper = state.sleepers.removeValue(forKey: id) else {
          state.cancelled.insert(id)
          return CancellationAction(sleeper: nil, countWaiters: [])
        }
        return CancellationAction(
          sleeper: sleeper,
          countWaiters: takeSatisfiedCountWaiters(state: &state)
        )
      }
      action.sleeper?.continuation.resume(throwing: CancellationError())
      for waiter in action.countWaiters { waiter.resume() }
    }
  }

  func advance(by duration: Duration) {
    let action = state.withLock { state -> AdvanceAction in
      state.now = state.now.advanced(by: duration)
      let ready = state.sleepers.filter { $0.value.deadline <= state.now }
      for id in ready.keys { state.sleepers.removeValue(forKey: id) }
      return AdvanceAction(
        sleepers: ready.values.map(\.continuation),
        countWaiters: takeSatisfiedCountWaiters(state: &state)
      )
    }
    for sleeper in action.sleepers { sleeper.resume() }
    for waiter in action.countWaiters { waiter.resume() }
  }

  func waitForSleepCount(_ count: Int) async {
    await withCheckedContinuation { continuation in
      let shouldResume = state.withLock { state in
        guard state.sleepers.count != count else { return true }
        state.countWaiters[UUID()] = CountWaiter(count: count, continuation: continuation)
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }

  private func takeSatisfiedCountWaiters(
    state: inout State
  ) -> [CheckedContinuation<Void, Never>] {
    let satisfied = state.countWaiters.filter { $0.value.count == state.sleepers.count }
    for id in satisfied.keys { state.countWaiters.removeValue(forKey: id) }
    return satisfied.values.map(\.continuation)
  }

  private struct SleepAction {
    let result: Result<Void, any Error>?
    let countWaiters: [CheckedContinuation<Void, Never>]
  }

  private struct CancellationAction {
    let sleeper: Sleeper?
    let countWaiters: [CheckedContinuation<Void, Never>]
  }

  private struct AdvanceAction {
    let sleepers: [CheckedContinuation<Void, any Error>]
    let countWaiters: [CheckedContinuation<Void, Never>]
  }
}
