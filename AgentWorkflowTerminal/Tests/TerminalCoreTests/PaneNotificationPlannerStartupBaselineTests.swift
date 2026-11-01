import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知: 起動時の基準が先に読んだ記録を消さない (§11.2、#509)")
struct PaneNotificationStartupBaselineTests: PaneNotificationPlannerTesting {
  let worktree: WorktreeIdentity
  let other: WorktreeIdentity
  let sessionA: TerminalSessionKey
  let sessionB: TerminalSessionKey

  init() throws {
    let identities = try Self.identities()
    worktree = identities.worktree
    other = identities.other
    sessionA = try #require(TerminalSessionKey(identity: identities.worktree, index: 1))
    sessionB = try #require(TerminalSessionKey(identity: identities.worktree, index: 2))
  }

  @Test("H8: 完了表示が状態の基準より先でも、同じ token を次の観測で鳴らさない")
  func completionBaselineSurvivesStatesBaseline() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(displays(&planner, ["%1": .completed(Self.first)], at: start).isEmpty)
    #expect(states(&planner, [pane("%1", .completed)], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)

    let next = start.advanced(by: .seconds(2))
    #expect(displays(&planner, ["%1": .completed(Self.first)], at: next).isEmpty)
    #expect(states(&planner, [pane("%1", .completed)], in: sessionA, at: next).isEmpty)
  }

  @Test("H9: 完了表示の基準を取れなかった pane は、状態の基準の後に判定できた token を鳴らさない")
  func undeterminedCompletionBaselineSurvivesStatesBaseline() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(
      displays(&planner, ["%1": .completed(Self.first)], undetermined: ["%1"], at: start)
        .isEmpty)
    #expect(states(&planner, [pane("%1", .completed)], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)

    let next = start.advanced(by: .seconds(2))
    #expect(displays(&planner, ["%1": .completed(Self.first)], at: next).isEmpty)
  }

  @Test("既知の pane が plain Unknown のまま別の session の基準に現れても、最初に Unknown になった時刻から数える")
  func knownUnknownPaneKeepsTimerAcrossNewSessionBaseline() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner(settings: Self.withProlongedUnknown)
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .working)], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)

    let unknownAt = start.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%1", .unknown)], in: sessionA, at: unknownAt).isEmpty)
    let deadline = unknownAt.advanced(by: planner.settings.unknownThreshold)
    #expect(planner.nextDeadline == deadline)

    let joined = unknownAt.advanced(by: .seconds(180))
    planner.startObserving(sessionB, at: joined)
    #expect(states(&planner, [pane("%1", .unknown)], in: sessionB, at: joined).isEmpty)
    #expect(planner.nextDeadline == deadline)
    #expect(planner.advance(to: deadline.advanced(by: .milliseconds(-1))).isEmpty)
    #expect(
      planner.advance(to: deadline)
        == [
          .pane(
            PaneNotificationEvent(
              session: sessionB, paneID: PaneID(rawValue: "%1"), kind: .prolongedUnknown,
              completion: nil))
        ])
    #expect(planner.advance(to: joined.advanced(by: planner.settings.unknownThreshold)).isEmpty)
    #expect(planner.nextDeadline == nil)
  }

  private func states(
    _ planner: inout PaneNotificationPlanner, _ panes: [PaneAgentState],
    in session: TerminalSessionKey, at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    planner.observeStates(complete(panes), in: session, at: instant)
  }

  private func displays(
    _ planner: inout PaneNotificationPlanner, _ values: [String: PaneTaskCompletionDisplay],
    undetermined: Set<String> = [], at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    planner.observeCompletions(
      Self.keyed(values), undetermined: Set(undetermined.map(PaneID.init(rawValue:))),
      in: sessionA, at: instant)
  }
}
