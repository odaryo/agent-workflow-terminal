import Foundation

@testable import TerminalCore

enum TestError: Error { case failed }

actor ScriptedPaneSource: WorktreePaneSource {
  private let results: [Result<[PaneSnapshot], TestError>]
  private var callCount = 0

  init(results: [Result<[PaneSnapshot], TestError>]) { self.results = results }

  func panes(of session: TerminalSessionKey) async throws -> [PaneSnapshot] {
    let index = min(callCount, results.count - 1)
    callCount += 1
    return try results[index].get()
  }

  func waitForCalls(_ expected: Int) async -> Bool {
    let deadline = ContinuousClock().now.advanced(by: .seconds(10))
    while callCount < expected, !Task.isCancelled, ContinuousClock().now < deadline {
      await Task.yield()
    }
    return callCount >= expected
  }
}

actor FeedSignalSource: AgentSignalSource {
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

struct FeedAdapter: AgentAdapter {
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

actor ObservationChannel {
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

actor FeedTestClock: ContinuousTimeSource {
  nonisolated let now = ContinuousClock().now
  private var sleepers: [CheckedContinuation<Void, any Error>] = []
  private(set) var sleepCount = 0

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await withCheckedThrowingContinuation { continuation in
      sleepCount += 1
      sleepers.append(continuation)
    }
  }

  /// 配信を受け取れても poll ループはまだ sleep に入っていないことがあり、その前の `advance()` は
  /// 空振りして次の周期が永遠に来ない。`advance()` の前にこれで登録を待つ。
  func waitForSleep(_ count: Int) async -> Bool {
    let deadline = ContinuousClock().now.advanced(by: .seconds(10))
    while sleepCount < count, ContinuousClock().now < deadline { await Task.yield() }
    return sleepCount >= count
  }

  func advance() {
    let current = sleepers
    sleepers.removeAll()
    for sleeper in current { sleeper.resume() }
  }
}
