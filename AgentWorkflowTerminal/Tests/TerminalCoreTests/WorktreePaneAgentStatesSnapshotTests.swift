import Foundation
import Testing

@testable import TerminalCore

/// 偽の pane source・adapter・時計は `WorktreePaneAgentStateFeedTests.swift` のものを使う。
@Suite("worktree 単位の pane Agent 状態列の揃い (#387)")
struct WorktreePaneAgentStatesSnapshotTests {
  @Test("全 pane の最初の結果 (observation か absent) が揃うまでは未完として配信する")
  func reportsCompleteness() async throws {
    let context = try makeContext(panes: [.success([pane("%1"), pane("%2")])])
    var iterator = context.stream.makeAsyncIterator()
    #expect(await iterator.next() == WorktreePaneAgentStates(panes: [], isComplete: false))
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))
    await context.channel.send(observation(.question), to: PaneID(rawValue: "%1"))
    let partial = await iterator.next()
    #expect(partial?.panes.map(\.id) == [PaneID(rawValue: "%1")])
    #expect(partial?.isComplete == false)

    // 一覧が変わらなくても、揃ったことは配信する。
    await context.channel.waitForSubscriber(PaneID(rawValue: "%2"))
    await context.channel.send(.absent, to: PaneID(rawValue: "%2"))
    let settled = await iterator.next()
    #expect(settled?.panes.map(\.id) == [PaneID(rawValue: "%1")])
    #expect(settled?.isComplete == true)
  }

  @Test("pane が1つも無ければ最初の配信から揃っている")
  func withoutPanesIsComplete() async throws {
    let context = try makeContext(panes: [.success([])])
    var iterator = context.stream.makeAsyncIterator()
    #expect(await iterator.next() == WorktreePaneAgentStates(panes: [], isComplete: true))
  }

  @Test("後から現れた pane の結果が届くまでは再び未完になる")
  func becomesIncompleteForNewPane() async throws {
    let context = try makeContext(panes: [.success([]), .success([pane("%1")])])
    var iterator = context.stream.makeAsyncIterator()
    #expect(await iterator.next() == WorktreePaneAgentStates(panes: [], isComplete: true))
    await context.clock.advance()
    #expect(await iterator.next() == WorktreePaneAgentStates(panes: [], isComplete: false))
    await context.channel.waitForSubscriber(PaneID(rawValue: "%1"))
    await context.channel.send(observation(.permission), to: PaneID(rawValue: "%1"))
    let settled = await iterator.next()
    #expect(settled?.panes.map(\.state) == [.permission])
    #expect(settled?.isComplete == true)
  }

  private struct Context {
    let stream: AsyncStream<WorktreePaneAgentStates>
    let channel: ObservationChannel
    let clock: FeedTestClock
  }

  private func makeContext(panes: [Result<[PaneSnapshot], TestError>]) throws -> Context {
    let channel = ObservationChannel()
    let clock = FeedTestClock()
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let stream = WorktreePaneAgentStateFeed(
      adapters: [FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)],
      fallback: FeedAdapter(id: "fallback", processNames: [], channel: channel),
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      paneListInterval: .seconds(1)
    ).snapshots(
      of: worktree, panes: ScriptedPaneSource(results: panes),
      signals: FeedSignalSource(aliveNames: ["agent"]), timeSource: clock)
    return Context(stream: stream, channel: channel, clock: clock)
  }

  private func pane(_ id: String) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: id), processID: 100, tty: "/dev/ttys001", currentCommand: "agent",
      currentPath: "/repo", title: "pane", termination: nil)
  }

  private func observation(_ state: AgentState) -> AgentObservationResult {
    .observation(
      AgentStateObservation(
        state: state, adapterID: AgentAdapterID(rawValue: "matched"),
        observedAt: Date(timeIntervalSince1970: 1)))
  }
}
