import Foundation
import Testing

@testable import TerminalCore

@Suite("初回観測が揃うまでの pane 配信 (設計書 §13 / Issue #387)")
struct WorktreePaneFeedInitialObservationTests {
  @Test("states は最初の全 pane の結果が揃うまで空配列も部分結果も配信しない", arguments: [0, 1])
  func statesSuppressIncompleteInitialObservations(resultCount: Int) async {
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = coordinator(output: .states(pair.continuation))
    await coordinator.receive([pane("%1"), pane("%2")])
    if resultCount == 1 {
      await coordinator.receive(observation(.working), paneID: id("%2"), generation: 0)
    }
    await coordinator.cancel()

    var values: [[PaneAgentState]] = []
    for await value in pair.stream { values.append(value) }
    #expect(values.isEmpty)
  }

  @Test("states の初回配信は absent も含め全 pane の結果を待ち、その後は状態変化を配信する")
  func firstStatesWaitForAbsentAsWellAsAgentObservations() async {
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = coordinator(output: .states(pair.continuation))
    await coordinator.receive([pane("%1"), pane("%2")])
    await coordinator.receive(observation(.working), paneID: id("%2"), generation: 0)
    await coordinator.receive(.absent, paneID: id("%1"), generation: 0)
    await coordinator.receive(observation(.idle), paneID: id("%2"), generation: 0)
    await coordinator.cancel()

    var values: [[PaneAgentState]] = []
    for await value in pair.stream { values.append(value) }
    #expect(values.map { $0.map(\.id) } == [[id("%2")], [id("%2")]])
    #expect(values.map { $0.map(\.state) } == [[.working], [.idle]])
  }

  @Test("全 pane が absent の初回結果は空配列を1回配信する")
  func allAbsentProducesOneEmptyResult() async {
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = coordinator(output: .states(pair.continuation))
    await coordinator.receive([pane("%1"), pane("%2")])
    await coordinator.receive(.absent, paneID: id("%1"), generation: 0)
    await coordinator.receive(.absent, paneID: id("%2"), generation: 0)
    await coordinator.cancel()

    var values: [[PaneAgentState]] = []
    for await value in pair.stream { values.append(value) }
    #expect(values == [[]])
  }

  @Test("初回に未観測の pane が一覧から消えたら、残りの結果で完全な初回配信をする")
  func removingUnobservedPaneCanCompleteInitialObservation() async {
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = coordinator(output: .states(pair.continuation))
    await coordinator.receive([pane("%1"), pane("%2")])
    await coordinator.receive(observation(.working), paneID: id("%1"), generation: 0)
    await coordinator.receive([pane("%1")])
    await coordinator.cancel()

    var values: [[PaneAgentState]] = []
    for await value in pair.stream { values.append(value) }
    #expect(values.map { $0.map(\.id) } == [[id("%1")]])
  }

  @Test("pane が0個の一覧は Adapter を待たず空配列を配信する")
  func emptyPaneListIsImmediatelyComplete() async {
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = coordinator(output: .states(pair.continuation))
    await coordinator.receive([])
    var iterator = pair.stream.makeAsyncIterator()

    #expect(await iterator.next() == [])
    await coordinator.cancel()
    #expect(await iterator.next() == nil)
  }

  @Test("一度完全になった states は追加 pane が未観測でも既存 pane の変化を配信する")
  func statesContinuePublishingAfterFirstCompleteResult() async {
    let pair = AsyncStream<[PaneAgentState]>.makeStream()
    let coordinator = coordinator(output: .states(pair.continuation))
    await coordinator.receive([pane("%1")])
    await coordinator.receive(observation(.working), paneID: id("%1"), generation: 0)
    await coordinator.receive([pane("%1"), pane("%2")])
    await coordinator.receive(observation(.question), paneID: id("%1"), generation: 0)
    await coordinator.receive(observation(.idle), paneID: id("%2"), generation: 0)
    await coordinator.cancel()

    var values: [[PaneAgentState]] = []
    for await value in pair.stream { values.append(value) }
    #expect(values.map { $0.map(\.state) } == [[.working], [.question], [.question, .idle]])
    #expect(values.last?.map(\.id) == [id("%1"), id("%2")])
  }

  @Test("snapshots は従来どおり未完の空配列・部分結果・完全な結果を配信する")
  func snapshotsStillPublishIncompleteResults() async {
    let pair = AsyncStream<WorktreePaneAgentStates>.makeStream()
    let coordinator = coordinator(output: .snapshots(pair.continuation))
    await coordinator.receive([pane("%1"), pane("%2")])
    await coordinator.receive(observation(.working), paneID: id("%2"), generation: 0)
    await coordinator.receive(.absent, paneID: id("%1"), generation: 0)
    await coordinator.cancel()

    var values: [WorktreePaneAgentStates] = []
    for await value in pair.stream { values.append(value) }
    #expect(values.map(\.isComplete) == [false, false, true])
    #expect(values.map { $0.panes.map(\.id) } == [[], [id("%2")], [id("%2")]])
  }

  private func coordinator(
    output: WorktreePaneFeedCoordinator.Output
  ) -> WorktreePaneFeedCoordinator {
    let channel = ObservationChannel()
    return WorktreePaneFeedCoordinator(
      adapters: [FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)],
      fallback: FeedAdapter(id: "fallback", processNames: [], channel: channel),
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)), output: output,
      signalSource: FeedSignalSource(aliveNames: ["agent"]))
  }

  private func pane(_ rawValue: String) -> PaneSnapshot {
    PaneSnapshot(
      id: id(rawValue), processID: 100, tty: "/dev/ttys001", currentCommand: "agent",
      currentPath: "/repo", title: "pane", termination: nil)
  }

  private func id(_ rawValue: String) -> PaneID { PaneID(rawValue: rawValue) }

  private func observation(_ state: AgentState) -> AgentObservationResult {
    .observation(
      AgentStateObservation(
        state: state, adapterID: AgentAdapterID(rawValue: "matched"),
        observedAt: Date(timeIntervalSince1970: 1)))
  }
}
