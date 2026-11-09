import Foundation
import TerminalCore
import Testing

@Suite("pane 一覧の観測失敗 (#295)")
struct WorktreePaneFeedListFailureTests {
  @Test("states(of:) は初回から一覧取得に2回失敗しても空配列を配信しない")
  func initialFailuresNeverPublishEmptyStates() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let channel = ObservationChannel()
    let clock = FeedTestClock()
    let recorder = FailureStatesRecorder()
    let feed = WorktreePaneAgentStateFeed(
      adapters: [FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)],
      fallback: FeedAdapter(id: "fallback", processNames: [], channel: channel),
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      paneListInterval: .seconds(2))
    let stream = feed.states(
      of: worktree, panes: ScriptedPaneSource(results: [.failure(.failed)]),
      signals: FeedSignalSource(aliveNames: ["agent"]), timeSource: clock)
    let consumer = Task {
      for await states in stream { await recorder.append(states) }
    }
    defer { consumer.cancel() }
    try #require(await clock.waitForSleep(1))
    await clock.advance()
    try #require(await clock.waitForSleep(2))

    #expect(await !recorder.waitForAnyValue())
    #expect(await recorder.values.isEmpty)
  }

  @Test("完了済みの空 session は1回の失敗では保持し、2回で一覧取得不能、成功で復旧する")
  func emptySessionFailureThresholdAndRecovery() async throws {
    let context = try FailureContext(
      results: [.success([]), .failure(.failed), .failure(.failed), .success([])])
    defer { context.consumer.cancel() }
    try #require(await context.recorder.waitFor { $0.isComplete })
    let initial = try #require(await context.recorder.values.last)
    #expect(initial.panes.isEmpty)
    #expect(!initial.isPaneListUnavailable)

    try await context.poll(2)
    #expect(
      await !context.recorder.waitFor(within: .milliseconds(200)) {
        !$0.isComplete || $0.isPaneListUnavailable
      })
    #expect(await context.recorder.values.last == initial)

    try await context.poll(3)
    #expect(await context.recorder.waitFor { !$0.isComplete && $0.isPaneListUnavailable })
    let failed = try #require(await context.recorder.values.last)
    #expect(failed.panes.isEmpty)
    #expect(!failed.isComplete)
    #expect(failed.isPaneListUnavailable)

    try await context.poll(4)
    try #require(await context.recorder.waitForLast { $0.isComplete })
    let recovered = try #require(await context.recorder.values.last)
    #expect(recovered.panes.isEmpty)
    #expect(!recovered.isPaneListUnavailable)
  }

  @Test("初回から一覧取得に2回失敗すると既知の pane が無くても一覧取得不能を配信する")
  func initialFailuresPublishPaneListUnavailable() async throws {
    let context = try FailureContext(results: [.failure(.failed)])
    defer { context.consumer.cancel() }
    try #require(await context.clock.waitForSleep(1))
    try #require(await context.recorder.waitFor { !$0.isComplete })
    #expect(await context.recorder.values.last?.isPaneListUnavailable == false)

    try await context.poll(2)

    #expect(await context.recorder.waitFor { $0.isPaneListUnavailable })
    let failed = try #require(await context.recorder.values.last)
    #expect(failed.panes.isEmpty)
    #expect(!failed.isComplete)
    #expect(failed.isPaneListUnavailable)
  }

  @Test("既知の Agent pane があっても一覧取得に2回失敗すると一覧取得不能を配信する")
  func knownPaneFailuresPublishPaneListUnavailable() async throws {
    let current = pane("%1")
    let context = try FailureContext(
      results: [.success([current]), .failure(.failed), .failure(.failed)])
    defer { context.consumer.cancel() }
    await context.channel.waitForSubscriber(current.id)
    await context.channel.send(.working, to: current.id)
    try #require(await context.recorder.waitFor { $0.isComplete })

    try await context.poll(2)
    #expect(await context.recorder.values.last?.isPaneListUnavailable == false)
    try await context.poll(3)

    try #require(await context.recorder.waitFor { $0.panes.first?.state == .unknown })
    let failed = try #require(await context.recorder.values.last)
    #expect(failed.panes.map(\.id) == [current.id])
    #expect(!failed.isComplete)
    #expect(failed.isPaneListUnavailable)
  }

  @Test("§12.4.2 absent の pane は一覧取得に2回失敗しても Unknown にならず不在のまま残る")
  func absentPaneRemainsAbsentDuringFailures() async throws {
    let panes = [pane("%1"), pane("%2")]
    let context = try FailureContext(
      results: [.success(panes), .failure(.failed), .failure(.failed)])
    defer { context.consumer.cancel() }
    await context.channel.waitForSubscribers(2)
    await context.channel.send(.working, to: panes[0].id)
    await context.channel.send(.absent, to: panes[1].id)
    try #require(await context.recorder.waitFor { $0.isComplete })

    try await context.poll(2)
    try await context.poll(3)

    try #require(await context.recorder.waitFor { $0.panes.first?.state == .unknown })
    let failed = try #require(await context.recorder.values.last)
    #expect(failed.panes.map(\.id) == [panes[0].id])
    #expect(failed.agentAbsentPanes == [panes[1].id])
  }

  @Test("§12.4.2 結果未着の pane は一覧取得に2回失敗しても Unknown として出さない")
  func pendingPaneIsNotPromotedToUnknown() async throws {
    let panes = [pane("%1"), pane("%2")]
    let context = try FailureContext(
      results: [.success(panes), .failure(.failed), .failure(.failed)])
    defer { context.consumer.cancel() }
    await context.channel.waitForSubscribers(2)
    await context.channel.send(.working, to: panes[0].id)
    try #require(await context.recorder.waitFor { $0.panes.map(\.id) == [panes[0].id] })

    try await context.poll(2)
    try await context.poll(3)

    try #require(await context.recorder.waitFor { $0.panes.first?.state == .unknown })
    let failed = try #require(await context.recorder.values.last)
    #expect(failed.panes.map(\.id) == [panes[0].id])
    #expect(failed.panes.allSatisfy { $0.unknownReason == .observationFailed })
    #expect(failed.agentAbsentPanes.isEmpty)
    #expect(!failed.isComplete)
  }

  @Test("一覧取得失敗で読み替えた Unknown は各 pane の直前の adapterID と lastKnownAt を保つ")
  func unknownPreservesLatestObservationMetadata() async throws {
    let panes = [pane("%1"), pane("%2")]
    let context = try FailureContext(
      results: [.success(panes), .failure(.failed), .failure(.failed)])
    defer { context.consumer.cancel() }
    await context.channel.waitForSubscribers(2)
    for pane in panes { await context.channel.send(.working, to: pane.id) }
    try #require(await context.recorder.waitFor { $0.isComplete })
    let observations = [
      AgentStateObservation(
        state: .idle, adapterID: .init(rawValue: "first-adapter"),
        observedAt: Date(timeIntervalSince1970: 30), lastKnownAt: Date(timeIntervalSince1970: 20)),
      AgentStateObservation(
        state: .unknown, adapterID: .init(rawValue: "second-adapter"),
        observedAt: Date(timeIntervalSince1970: 40), lastKnownAt: nil,
        unknownReason: .observationFailed),
    ]
    for (pane, observation) in zip(panes, observations) {
      await context.channel.send(.observation(observation), to: pane.id)
    }
    try #require(await context.recorder.waitFor { $0.panes.map(\.state) == [.idle, .unknown] })
    let previous = try #require(await context.recorder.values.last)

    try await context.poll(2)
    try await context.poll(3)

    try #require(
      await context.recorder.waitFor {
        !$0.isComplete && $0.panes.count == 2 && $0.panes.allSatisfy { $0.state == .unknown }
      })
    let failed = try #require(await context.recorder.values.last)
    #expect(failed.panes.map(\.id) == previous.panes.map(\.id))
    #expect(failed.panes.map(\.adapterID) == previous.panes.map(\.adapterID))
    #expect(failed.panes.map(\.lastKnownAt) == previous.panes.map(\.lastKnownAt))
  }

  @Test("1回の失敗では保持し、連続2回で全 pane を Unknown にして、成功時に最新の観測へ戻す")
  func consecutiveFailuresAndRecovery() async throws {
    let panes = [pane("%2"), pane("%1")]
    let context = try FailureContext(
      results: [.success(panes), .failure(.failed), .failure(.failed), .success(panes)])
    defer { context.consumer.cancel() }
    await context.channel.waitForSubscribers(2)
    await context.channel.send(.working, to: panes[0].id)
    await context.channel.send(.idle, to: panes[1].id)
    try #require(await context.recorder.waitFor { $0.isComplete && $0.panes.count == 2 })
    let initial = try #require(await context.recorder.values.last)

    try await context.poll(2)
    #expect(await context.recorder.values.last == initial)

    try await context.poll(3)
    try #require(
      await context.recorder.waitFor {
        !$0.isComplete && $0.panes.count == 2 && $0.panes.allSatisfy { $0.state == .unknown }
      })
    let failed = try #require(await context.recorder.values.last)
    #expect(failed.panes.map(\.id) == panes.map(\.id))
    #expect(failed.panes.allSatisfy { $0.unknownReason == .observationFailed })
    let diagnostics = try #require(failed.panes.first?.diagnostics)
    #expect(!diagnostics.isEmpty)
    #expect(failed.panes.allSatisfy { $0.diagnostics == diagnostics })
    for pane in panes {
      #expect(!diagnostics.contains(pane.currentPath))
      #expect(!diagnostics.contains(pane.title))
    }

    await context.channel.send(.completed, to: panes[0].id)
    await context.channel.send(.working, to: panes[1].id)
    try await context.poll(4)
    try #require(
      await context.recorder.waitFor {
        $0.isComplete && $0.panes.map(\.state) == [.completed, .working]
      })
    let recovered = try #require(await context.recorder.values.last)
    #expect(recovered.panes.map(\.id) == panes.map(\.id))
    #expect(recovered.panes.allSatisfy { $0.adapterID == .init(rawValue: "matched") })
    #expect(recovered.panes.allSatisfy { $0.unknownReason == nil && $0.diagnostics == nil })
  }

  @Test("成功を挟んだ失敗は連続失敗に数えず、状態と配信を変えない")
  func successResetsFailureCount() async throws {
    let current = pane("%1")
    let context = try FailureContext(
      results: [
        .success([current]), .failure(.failed), .success([current]), .failure(.failed),
        .success([current]),
      ])
    defer { context.consumer.cancel() }
    await context.channel.waitForSubscriber(current.id)
    await context.channel.send(.working, to: current.id)
    try #require(await context.recorder.waitFor { $0.isComplete })
    let baseline = await context.recorder.values

    for count in 2...5 { try await context.poll(count) }

    #expect(await context.recorder.values == baseline)
  }

  @Test("初回から一覧を取得できなければ空で未完のまま配信し、Agent 不在を確定しない")
  func initialFailuresNeverPublishComplete() async throws {
    let context = try FailureContext(results: [.failure(.failed)])
    defer { context.consumer.cancel() }
    try #require(await context.clock.waitForSleep(1))
    try #require(await context.recorder.waitFor { $0.panes.isEmpty && !$0.isComplete })

    try await context.poll(2)
    try await context.poll(3)

    let values = await context.recorder.values
    #expect(!values.isEmpty)
    #expect(values.allSatisfy { $0.panes.isEmpty && !$0.isComplete })
  }

  private func pane(_ id: String) -> PaneSnapshot {
    PaneSnapshot(
      id: .init(rawValue: id), processID: 100, tty: "/dev/ttys001",
      currentCommand: "agent", currentPath: "/private/project-\(id)",
      title: "confidential-title-\(id)", termination: nil)
  }
}

private struct FailureContext {
  let channel = ObservationChannel()
  let clock = FeedTestClock()
  let recorder = FailureSnapshotRecorder()
  let consumer: Task<Void, Never>

  init(results: [Result<[PaneSnapshot], TestError>]) throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let feed = WorktreePaneAgentStateFeed(
      adapters: [FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)],
      fallback: FeedAdapter(id: "fallback", processNames: [], channel: channel),
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      paneListInterval: .seconds(2))
    let stream = feed.snapshots(
      of: worktree, panes: ScriptedPaneSource(results: results),
      signals: FeedSignalSource(aliveNames: ["agent"]), timeSource: clock)
    let recorder = recorder
    consumer = Task {
      for await snapshot in stream { await recorder.append(snapshot) }
    }
  }

  func poll(_ count: Int) async throws {
    // 呼び出し回数だけでは catch / receive の完了を保証しないため、次の sleep 登録まで待つ。
    try #require(await clock.waitForSleep(count - 1))
    await clock.advance()
    try #require(await clock.waitForSleep(count))
    for _ in 0..<20 { await Task.yield() }
  }
}

private actor FailureSnapshotRecorder {
  private(set) var values: [WorktreePaneAgentStates] = []

  func append(_ snapshot: WorktreePaneAgentStates) { values.append(snapshot) }

  func waitFor(
    within limit: Duration = .seconds(10), _ predicate: @Sendable (WorktreePaneAgentStates) -> Bool
  ) async -> Bool {
    // 期限はテスト全体の負荷で 2 秒を超えた実測がある。来ないことの確認は呼び出し側で短くする。
    let deadline = ContinuousClock().now.advanced(by: limit)
    while !values.contains(where: predicate), ContinuousClock().now < deadline {
      await Task.yield()
    }
    return values.contains(where: predicate)
  }

  func waitForLast(_ predicate: @Sendable (WorktreePaneAgentStates) -> Bool) async -> Bool {
    let deadline = ContinuousClock().now.advanced(by: .seconds(10))
    while values.last.map(predicate) != true, ContinuousClock().now < deadline {
      await Task.yield()
    }
    return values.last.map(predicate) == true
  }
}

private actor FailureStatesRecorder {
  private(set) var values: [[PaneAgentState]] = []

  func append(_ states: [PaneAgentState]) { values.append(states) }

  func waitForAnyValue() async -> Bool {
    // 配信が無いことの確認なので、待つほどテストが遅くなる。sleep の登録後に呼ぶ前提で短くする。
    let deadline = ContinuousClock().now.advanced(by: .milliseconds(200))
    while values.isEmpty, ContinuousClock().now < deadline { await Task.yield() }
    return !values.isEmpty
  }
}
