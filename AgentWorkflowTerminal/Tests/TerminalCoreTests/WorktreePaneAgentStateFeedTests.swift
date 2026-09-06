import Foundation
import Testing

@testable import TerminalCore

@Suite("worktree 単位の pane Agent 状態列")
struct WorktreePaneAgentStateFeedTests {
  @Test("pane が現れると観測が一覧に現れる")
  func paneAppears() async throws {
    let context = try makeContext(panes: [.success([pane("%1")])])
    var iterator = context.stream.makeAsyncIterator()
    #expect(await iterator.next() == [])
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))
    await context.channel.send(
      observation(.working, adapter: "matched"), to: PaneID(rawValue: "%1"))
    #expect(await iterator.next()?.map(\.id) == [PaneID(rawValue: "%1")])
  }

  @Test("pane が消えると一覧から消え、信号保持も破棄する")
  func paneDisappears() async throws {
    let context = try makeContext(panes: [.success([pane("%1")]), .success([])])
    var iterator = context.stream.makeAsyncIterator()
    _ = await iterator.next()
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))
    await context.channel.send(
      observation(.working, adapter: "matched"), to: PaneID(rawValue: "%1"))
    _ = await iterator.next()
    await context.clock.advance()
    #expect(await iterator.next() == [])
    #expect(await context.signals.forgotten == [PaneID(rawValue: "%1")])
  }

  @Test("absent は pane を消さず、後続 observation で復帰する")
  func absentCanReturn() async throws {
    let context = try makeContext(panes: [.success([pane("%1")])])
    var iterator = context.stream.makeAsyncIterator()
    _ = await iterator.next()
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))
    await context.channel.send(
      observation(.working, adapter: "matched"), to: PaneID(rawValue: "%1"))
    _ = await iterator.next()
    await context.channel.send(.absent, to: PaneID(rawValue: "%1"))
    #expect(await iterator.next() == [])
    await context.channel.send(observation(.idle, adapter: "matched"), to: PaneID(rawValue: "%1"))
    #expect(await iterator.next()?.first?.state == .idle)
    #expect(await context.channel.cancellationCount == 0)
  }

  @Test("一致する adapter が無ければ fallback を選ぶ")
  func selectsFallback() async throws {
    let context = try makeContext(panes: [.success([pane("%1")])], aliveNames: [])
    var iterator = context.stream.makeAsyncIterator()
    _ = await iterator.next()
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))
    await context.channel.send(
      observation(.unknown, adapter: "fallback"), to: .init(rawValue: "%1"))
    #expect(await iterator.next()?.first?.adapterID == AgentAdapterID(rawValue: "fallback"))
  }

  @Test("processNames が生存する adapter を選ぶ")
  func selectsMatchingAdapter() async throws {
    let context = try makeContext(panes: [.success([pane("%1")])], aliveNames: ["agent"])
    var iterator = context.stream.makeAsyncIterator()
    _ = await iterator.next()
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))
    await context.channel.send(observation(.working, adapter: "matched"), to: .init(rawValue: "%1"))
    #expect(await iterator.next()?.first?.adapterID == AgentAdapterID(rawValue: "matched"))
  }

  @Test("別 pane の更新でも変化していない pane の観測を保持する")
  func retainsOtherPaneObservation() async throws {
    let context = try makeContext(panes: [.success([pane("%1"), pane("%2")])])
    var iterator = context.stream.makeAsyncIterator()
    _ = await iterator.next()
    await context.channel.waitForSubscribers(2)
    await context.channel.send(observation(.working, adapter: "matched"), to: .init(rawValue: "%1"))
    _ = await iterator.next()
    await context.channel.send(observation(.idle, adapter: "matched"), to: .init(rawValue: "%2"))
    #expect(await iterator.next()?.map(\.id) == [.init(rawValue: "%1"), .init(rawValue: "%2")])
  }

  @Test("同じ合成結果を重複配信しない")
  func suppressesDuplicates() async throws {
    let unchanged = pane("%1")
    let context = try makeContext(panes: [.success([unchanged]), .success([unchanged])])
    let recorder = FeedOutputRecorder()
    let consumer = Task {
      for await value in context.stream { await recorder.append(value) }
    }
    await recorder.waitForCount(1)
    await context.channel.waitForSubscriber(unchanged.id)
    let value = observation(.working, adapter: "matched")
    await context.channel.send(value, to: unchanged.id)
    await recorder.waitForCount(2)
    await context.clock.advance()
    await context.paneSource.waitForCalls(2)
    await context.channel.send(value, to: unchanged.id)
    for _ in 0..<20 { await Task.yield() }
    #expect(await recorder.count == 2)
    consumer.cancel()
  }

  @Test("pane 一覧取得失敗後も次の周期で回復する")
  func recoversAfterPaneListFailure() async throws {
    let context = try makeContext(panes: [.failure(TestError.failed), .success([pane("%1")])])
    var iterator = context.stream.makeAsyncIterator()
    await context.paneSource.waitForCalls(1)
    await context.clock.advance()
    #expect(await iterator.next() == [])
    await context.channel.waitForSubscriber(.init(rawValue: "%1"))
    await context.channel.send(observation(.working, adapter: "matched"), to: .init(rawValue: "%1"))
    #expect(await iterator.next()?.first?.id == PaneID(rawValue: "%1"))
  }

  @Test("出力 stream の終了で pane 観測タスクを cancel する")
  func cancellationStopsObservation() async throws {
    var context: TestContext? = try makeContext(panes: [.success([pane("%1")])])
    let channel = try #require(context?.channel)
    var stream: AsyncStream<[PaneAgentState]>? = context?.stream
    context = nil
    var iterator: AsyncStream<[PaneAgentState]>.Iterator? = stream?.makeAsyncIterator()
    _ = await iterator?.next()
    await channel.waitForSubscriber(.init(rawValue: "%1"))
    iterator = nil
    stream = nil
    await channel.waitForCancellations(1)
    #expect(await channel.cancellationCount == 1)
  }

  private func makeContext(
    panes: [Result<[PaneSnapshot], TestError>], aliveNames: Set<String> = ["agent"]
  ) throws -> TestContext {
    let channel = ObservationChannel()
    let paneSource = ScriptedPaneSource(results: panes)
    let signals = FeedSignalSource(aliveNames: aliveNames)
    let clock = FeedTestClock()
    let matched = FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)
    let fallback = FeedAdapter(id: "fallback", processNames: [], channel: channel)
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let stream = WorktreePaneAgentStateFeed(
      adapters: [matched], fallback: fallback,
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      paneListInterval: .seconds(1)
    ).states(of: worktree, panes: paneSource, signals: signals, timeSource: clock)
    return TestContext(
      stream: stream, paneSource: paneSource, signals: signals, channel: channel, clock: clock)
  }

  private func pane(_ id: String) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: id), processID: 100, tty: "/dev/ttys001",
      currentCommand: "agent", currentPath: "/repo", title: "pane", termination: nil)
  }

  private func observation(_ state: AgentState, adapter: String) -> AgentObservationResult {
    .observation(
      AgentStateObservation(
        state: state, adapterID: AgentAdapterID(rawValue: adapter),
        observedAt: Date(timeIntervalSince1970: 1)))
  }
}

private struct TestContext {
  let stream: AsyncStream<[PaneAgentState]>
  let paneSource: ScriptedPaneSource
  let signals: FeedSignalSource
  let channel: ObservationChannel
  let clock: FeedTestClock
}

private enum TestError: Error { case failed }

private actor ScriptedPaneSource: WorktreePaneSource {
  private let results: [Result<[PaneSnapshot], TestError>]
  private var callCount = 0

  init(results: [Result<[PaneSnapshot], TestError>]) { self.results = results }

  func panes(of worktree: WorktreeIdentity) async throws -> [PaneSnapshot] {
    let index = min(callCount, results.count - 1)
    callCount += 1
    return try results[index].get()
  }

  func waitForCalls(_ expected: Int) async {
    while callCount < expected { await Task.yield() }
  }
}

private actor FeedSignalSource: AgentSignalSource {
  private let aliveNames: Set<String>
  private(set) var forgotten: [PaneID] = []

  init(aliveNames: Set<String>) { self.aliveNames = aliveNames }

  func signals(for pane: PaneSnapshot) async throws -> AgentSignals {
    throw TestError.failed
  }

  func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    !aliveNames.isDisjoint(with: matchingProcessNames) ? .alive : .absent
  }

  func forget(_ pane: PaneSnapshot) async { forgotten.append(pane.id) }
}

private struct FeedAdapter: AgentAdapter {
  let id: AgentAdapterID
  let processNames: Set<String>
  let channel: ObservationChannel

  init(id: String, processNames: Set<String>, channel: ObservationChannel) {
    self.id = AgentAdapterID(rawValue: id)
    self.processNames = processNames
    self.channel = channel
  }

  func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult {
    .absent
  }

  func observations(
    of pane: PaneSnapshot, from source: any AgentSignalSource,
    intervals: AgentObservationIntervals
  ) -> AsyncStream<AgentObservationResult> {
    channel.stream(for: pane.id)
  }
}

private actor ObservationChannel {
  private var continuations: [PaneID: AsyncStream<AgentObservationResult>.Continuation] = [:]
  private(set) var cancellationCount = 0
  var subscriberCount: Int { continuations.count }

  nonisolated func stream(for paneID: PaneID) -> AsyncStream<AgentObservationResult> {
    AsyncStream { continuation in
      Task { await self.register(continuation, for: paneID) }
      continuation.onTermination = { _ in Task { await self.cancel(paneID) } }
    }
  }

  func send(_ value: AgentObservationResult, to paneID: PaneID) {
    continuations[paneID]?.yield(value)
  }

  func waitForSubscriber(_ paneID: PaneID) async {
    while continuations[paneID] == nil { await Task.yield() }
  }

  func waitForSubscribers(_ count: Int) async {
    while continuations.count < count { await Task.yield() }
  }

  func waitForCancellations(_ count: Int) async {
    while cancellationCount < count { await Task.yield() }
  }

  private func register(
    _ continuation: AsyncStream<AgentObservationResult>.Continuation, for paneID: PaneID
  ) {
    continuations[paneID] = continuation
  }

  private func cancel(_ paneID: PaneID) {
    continuations.removeValue(forKey: paneID)
    cancellationCount += 1
  }
}

private actor FeedOutputRecorder {
  private var values: [[PaneAgentState]] = []
  var count: Int { values.count }

  func append(_ value: [PaneAgentState]) { values.append(value) }

  func waitForCount(_ expected: Int) async {
    while values.count < expected { await Task.yield() }
  }
}

private actor FeedTestClock: ContinuousTimeSource {
  nonisolated let now = ContinuousClock().now
  private var sleepers: [CheckedContinuation<Void, any Error>] = []

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await withCheckedThrowingContinuation { continuation in sleepers.append(continuation) }
  }

  func advance() {
    let current = sleepers
    sleepers.removeAll()
    for sleeper in current { sleeper.resume() }
  }
}
