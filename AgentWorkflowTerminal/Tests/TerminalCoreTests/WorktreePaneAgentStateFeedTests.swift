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
    let context = try makeContext(panes: [.success([pane("%2"), pane("%1")])])
    var iterator = context.stream.makeAsyncIterator()
    _ = await iterator.next()
    await context.channel.waitForSubscribers(2)
    await context.channel.send(observation(.working, adapter: "matched"), to: .init(rawValue: "%2"))
    _ = await iterator.next()
    await context.channel.send(observation(.idle, adapter: "matched"), to: .init(rawValue: "%1"))
    #expect(await iterator.next()?.map(\.id) == [.init(rawValue: "%2"), .init(rawValue: "%1")])
  }

  @Test("processID・currentCommand・isDead の変化ごとに再選択して保持値を途切れさせない")
  func reselectsForProcessChangesWithoutDroppingObservation() async throws {
    let cases = [
      ReselectionCase(
        initial: pane("%1"), changed: pane("%1", processID: 200),
        preferredNames: [100: "agent", 200: "node"], expectedAdapterID: .init(rawValue: "node")),
      ReselectionCase(
        initial: pane("%1"), changed: pane("%1", currentCommand: "node"), preferredNames: [:],
        expectedAdapterID: .init(rawValue: "node")),
      ReselectionCase(
        initial: pane("%1"), changed: pane("%1", termination: .unknown), preferredNames: [:],
        expectedAdapterID: .init(rawValue: "fallback")),
    ]

    for testCase in cases {
      let context = try makeContext(
        panes: [.success([testCase.initial]), .success([testCase.changed])],
        aliveNames: ["agent", "node"], preferredProcessNames: testCase.preferredNames)
      var iterator = context.stream.makeAsyncIterator()
      _ = await iterator.next()
      await context.channel.waitForSubscriber(testCase.initial.id)
      await context.channel.send(.working, to: testCase.initial.id)
      #expect(await iterator.next()?.first?.adapterID == AgentAdapterID(rawValue: "matched"))

      await context.clock.advance()
      await context.paneSource.waitForCalls(2)
      for _ in 0..<20 { await Task.yield() }
      let selectedAdapterID = await context.channel.adapterID(for: testCase.changed.id)
      #expect(selectedAdapterID == testCase.expectedAdapterID)
      guard selectedAdapterID == testCase.expectedAdapterID else { continue }
      await context.channel.send(.idle, to: testCase.changed.id)

      #expect(await iterator.next()?.first?.adapterID == testCase.expectedAdapterID)
      for _ in 0..<20 { await Task.yield() }
      #expect(await context.channel.cancellationCount == 1)
    }
  }

  @Test("title と currentPath の変化では再選択しない")
  func doesNotReselectForPresentationChanges() async throws {
    let initial = pane("%1")
    let changed = pane("%1", currentPath: "/other", title: "renamed")
    let context = try makeContext(panes: [.success([initial]), .success([changed])])
    var iterator = context.stream.makeAsyncIterator()
    _ = await iterator.next()
    await context.channel.waitForSubscriber(initial.id)
    await context.channel.send(.working, to: initial.id)
    _ = await iterator.next()

    await context.clock.advance()
    await context.paneSource.waitForCalls(2)
    for _ in 0..<20 { await Task.yield() }

    #expect(await context.signals.livenessCallCount == 2)
    #expect(await context.channel.cancellationCount == 0)
  }

  @Test("再選択前の世代から遅れて届いた観測を無視する")
  func ignoresObservationFromSupersededGeneration() async {
    let channel = ObservationChannel()
    let signals = FeedSignalSource(aliveNames: ["agent", "node"])
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = WorktreePaneFeedCoordinator(
      adapters: [FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)],
      fallback: FeedAdapter(id: "fallback", processNames: [], channel: channel),
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      continuation: pair.continuation, signalSource: signals)
    let paneID = PaneID(rawValue: "%1")
    var iterator = pair.stream.makeAsyncIterator()

    await coordinator.receive([pane("%1")])
    _ = await iterator.next()
    await coordinator.receive(
      observation(.working, adapter: "matched"), paneID: paneID, generation: 0)
    _ = await iterator.next()
    await coordinator.receive([pane("%1", currentCommand: "node")])
    await coordinator.receive(observation(.idle, adapter: "matched"), paneID: paneID, generation: 0)
    await coordinator.receive(
      observation(.completed, adapter: "fallback"), paneID: paneID, generation: 1)

    #expect(await iterator.next()?.first?.state == .completed)
    await coordinator.cancel()
  }

  /// 解放の義務が feed 側にある理由は `WorktreePaneFeedCoordinator.cancel()` の doc に書いた。
  /// `receive(_ panes:)` の削除経路だけが `forget` を呼ぶ状態だと、止めた worktree の pane が
  /// 共有の登録集合に残り続ける。
  @Test("coordinator を止めたら登録した pane をすべて解放する")
  func cancelReleasesEveryRegisteredPane() async {
    let channel = ObservationChannel()
    let signals = FeedSignalSource(aliveNames: ["agent"])
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = WorktreePaneFeedCoordinator(
      adapters: [FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)],
      fallback: FeedAdapter(id: "fallback", processNames: [], channel: channel),
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      continuation: pair.continuation, signalSource: signals)

    await coordinator.receive([pane("%1"), pane("%2")])
    await coordinator.cancel()

    #expect(Set(await signals.forgotten) == [PaneID(rawValue: "%1"), PaneID(rawValue: "%2")])
  }

  @Test("stream の消費を止めたら登録した pane を解放する")
  func terminatingStreamReleasesRegisteredPanes() async throws {
    let context = try makeContext(panes: [.success([pane("%1")])])
    let recorder = FeedOutputRecorder()
    let consumer = Task {
      for await value in context.stream { await recorder.append(value) }
    }
    await recorder.waitForCount(1)
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))

    consumer.cancel()
    // `onTermination` は解放を別 Task で行うので、観測できるまで待つ。
    for _ in 0..<10_000 where await context.signals.forgotten.isEmpty {
      await Task.yield()
    }

    #expect(await context.signals.forgotten == [PaneID(rawValue: "%1")])
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

  @Test("保持中の pane 一覧取得失敗は状態も配信も破棄しない")
  func preservesStateAcrossPaneListFailure() async throws {
    let current = pane("%1")
    let context = try makeContext(
      panes: [.success([current]), .failure(TestError.failed), .success([current])])
    let recorder = FeedOutputRecorder()
    let consumer = Task {
      for await value in context.stream { await recorder.append(value) }
    }
    await recorder.waitForCount(1)
    await context.channel.waitForSubscriber(current.id)
    await context.channel.send(.working, to: current.id)
    await recorder.waitForCount(2)

    await context.clock.advance()
    await context.paneSource.waitForCalls(2)
    for _ in 0..<20 { await Task.yield() }
    #expect(await recorder.count == 2)
    #expect(await context.channel.cancellationCount == 0)

    await context.clock.advance()
    await context.paneSource.waitForCalls(3)
    for _ in 0..<20 { await Task.yield() }
    #expect(await recorder.count == 2)
    #expect(await context.channel.cancellationCount == 0)
    consumer.cancel()
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
    panes: [Result<[PaneSnapshot], TestError>], aliveNames: Set<String> = ["agent"],
    preferredProcessNames: [Int32: String] = [:]
  ) throws -> TestContext {
    let channel = ObservationChannel()
    let paneSource = ScriptedPaneSource(results: panes)
    let signals = FeedSignalSource(
      aliveNames: aliveNames, preferredProcessNames: preferredProcessNames)
    let clock = FeedTestClock()
    let matched = FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)
    let node = FeedAdapter(id: "node", processNames: ["node"], channel: channel)
    let fallback = FeedAdapter(id: "fallback", processNames: [], channel: channel)
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let stream = WorktreePaneAgentStateFeed(
      adapters: [matched, node], fallback: fallback,
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      paneListInterval: .seconds(1)
    ).states(of: worktree, panes: paneSource, signals: signals, timeSource: clock)
    return TestContext(
      stream: stream, paneSource: paneSource, signals: signals, channel: channel, clock: clock)
  }

  private func pane(
    _ id: String, processID: Int32 = 100, currentCommand: String = "agent",
    currentPath: String = "/repo", title: String = "pane",
    termination: ProcessTermination? = nil
  ) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: id), processID: processID, tty: "/dev/ttys001",
      currentCommand: currentCommand, currentPath: currentPath, title: title,
      termination: termination)
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
  private let preferredProcessNames: [Int32: String]
  private(set) var forgotten: [PaneID] = []
  private(set) var livenessCallCount = 0

  init(aliveNames: Set<String>, preferredProcessNames: [Int32: String] = [:]) {
    self.aliveNames = aliveNames
    self.preferredProcessNames = preferredProcessNames
  }

  func signals(
    for pane: PaneSnapshot, minimumChangedLines: Int
  ) async throws -> AgentSignals {
    throw TestError.failed
  }

  func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    livenessCallCount += 1
    let preferred = preferredProcessNames[pane.processID] ?? pane.currentCommand
    return aliveNames.contains(preferred) && matchingProcessNames.contains(preferred)
      ? .alive : .absent
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
    channel.stream(for: pane.id, adapterID: id)
  }
}

private actor ObservationChannel {
  private struct Subscription {
    let id: UUID
    let adapterID: AgentAdapterID
    let continuation: AsyncStream<AgentObservationResult>.Continuation
  }

  private var subscriptions: [PaneID: [Subscription]] = [:]
  private(set) var cancellationCount = 0
  var subscriberCount: Int { subscriptions.values.reduce(0) { $0 + $1.count } }

  nonisolated func stream(
    for paneID: PaneID, adapterID: AgentAdapterID
  ) -> AsyncStream<AgentObservationResult> {
    let subscriptionID = UUID()
    return AsyncStream { continuation in
      Task {
        await self.register(
          continuation, for: paneID, adapterID: adapterID, subscriptionID: subscriptionID)
      }
      continuation.onTermination = { _ in
        Task { await self.cancel(paneID, subscriptionID: subscriptionID) }
      }
    }
  }

  func send(_ value: AgentObservationResult, to paneID: PaneID) {
    subscriptions[paneID]?.last?.continuation.yield(value)
  }

  func send(_ state: AgentState, to paneID: PaneID) {
    guard let subscription = subscriptions[paneID]?.last else { return }
    subscription.continuation.yield(
      .observation(
        AgentStateObservation(
          state: state, adapterID: subscription.adapterID,
          observedAt: Date(timeIntervalSince1970: 1))))
  }

  func waitForSubscriber(_ paneID: PaneID) async {
    while subscriptions[paneID]?.isEmpty != false { await Task.yield() }
  }

  func waitForSubscribers(_ count: Int) async {
    while subscriberCount < count { await Task.yield() }
  }

  func adapterID(for paneID: PaneID) -> AgentAdapterID? { subscriptions[paneID]?.last?.adapterID }

  func waitForCancellations(_ count: Int) async {
    while cancellationCount < count { await Task.yield() }
  }

  private func register(
    _ continuation: AsyncStream<AgentObservationResult>.Continuation, for paneID: PaneID,
    adapterID: AgentAdapterID, subscriptionID: UUID
  ) {
    subscriptions[paneID, default: []].append(
      Subscription(id: subscriptionID, adapterID: adapterID, continuation: continuation))
  }

  private func cancel(_ paneID: PaneID, subscriptionID: UUID) {
    subscriptions[paneID]?.removeAll { $0.id == subscriptionID }
    if subscriptions[paneID]?.isEmpty == true { subscriptions.removeValue(forKey: paneID) }
    cancellationCount += 1
  }
}

private struct ReselectionCase {
  let initial: PaneSnapshot
  let changed: PaneSnapshot
  let preferredNames: [Int32: String]
  let expectedAdapterID: AgentAdapterID
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
