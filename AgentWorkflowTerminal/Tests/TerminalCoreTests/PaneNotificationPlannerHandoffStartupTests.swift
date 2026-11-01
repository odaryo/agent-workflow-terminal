import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知: pane 引き継ぎ時の起動順序 (#494)")
struct PaneNotificationHandoffStartupTests: PaneNotificationPlannerTesting {
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

  @Test("P1 / P1b: 完了表示が先でも判断待ちをまとめ、次の観測で個別に鳴らさない", arguments: [false, true])
  func completionBeforeStateBaseline(incompleteFirst: Bool) {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    if incompleteFirst {
      #expect(planner.observeStates(incomplete([]), in: sessionA, at: start).isEmpty)
    }
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: start).isEmpty)

    #expect(planner.setSummaryGate(isOpen: true, at: start) == [.attentionSummary(count: 1)])
    let next = start.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: next).isEmpty)
  }

  @Test("Q4: 2つの session で完了表示が先でも判断待ちを2件のまとめ通知にする")
  func completionsBeforeBothSessionBaselines() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%2": .none], in: sessionB, at: start).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: start).isEmpty)
    #expect(states(&planner, [pane("%2", .question)], in: sessionB, at: start).isEmpty)

    #expect(planner.setSummaryGate(isOpen: true, at: start) == [.attentionSummary(count: 2)])
    let next = start.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: next).isEmpty)
    #expect(states(&planner, [pane("%2", .question)], in: sessionB, at: next).isEmpty)
  }

  @Test("P5: 起動途中で開いた B も完了表示が先なら判断待ちをまとめ通知に含める")
  func sessionOpenedDuringStartupJoinsSummary() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)

    let opened = start.advanced(by: .seconds(1))
    planner.startObserving(sessionB, at: opened)
    #expect(displays(&planner, ["%2": .none], in: sessionB, at: opened).isEmpty)
    #expect(states(&planner, [pane("%2", .question)], in: sessionB, at: opened).isEmpty)

    #expect(planner.setSummaryGate(isOpen: true, at: opened) == [.attentionSummary(count: 2)])
    #expect(states(&planner, [pane("%2", .question)], in: sessionB, at: opened).isEmpty)
  }

  @Test("Q3: A と B の基準に同じ判断待ちの pane があってもまとめ通知は1件で60秒後も鳴らさない")
  func linkedPaneInBothBaselinesIsCountedOnce() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    for session in [sessionA, sessionB] {
      #expect(states(&planner, [pane("%1", .question)], in: session, at: start).isEmpty)
      #expect(displays(&planner, ["%1": .none], in: session, at: start).isEmpty)
    }

    #expect(planner.setSummaryGate(isOpen: true, at: start) == [.attentionSummary(count: 1)])
    let later = start.advanced(by: .seconds(60))
    #expect(planner.advance(to: later).isEmpty)
    for session in [sessionA, sessionB] {
      #expect(states(&planner, [pane("%1", .question)], in: session, at: later).isEmpty)
    }
  }

  @Test("P2: gate が開く前に停止し1秒後に再開しても判断待ちのまとめ通知を保つ")
  func restartedSessionKeepsPendingSummary() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    planner.stopObserving(sessionA)

    let resumed = start.advanced(by: .seconds(1))
    planner.startObserving(sessionA, at: resumed)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: resumed).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: resumed).isEmpty)

    #expect(planner.setSummaryGate(isOpen: true, at: resumed) == [.attentionSummary(count: 1)])
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: resumed).isEmpty)
  }

  @Test("猶予の1ms前は通知済み記録を引き継ぎ、猶予ちょうどでは新しい pane とする", arguments: [true, false])
  func returningPaneAtGraceBoundary(beforeBoundary: Bool) {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    #expect(states(&planner, [pane("%1", .working)], in: sessionA, at: start).isEmpty)
    #expect(states(&planner, [], in: sessionB, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, [:], in: sessionB, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionA, at: start)
        == [notification(in: sessionA, kind: .question)])
    #expect(
      displays(&planner, ["%1": .completed(Self.first)], in: sessionA, at: start)
        == [notification(in: sessionA, kind: .taskCompleted, completion: Self.first)])
    #expect(states(&planner, [], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, [:], in: sessionA, at: start).isEmpty)

    let elapsed =
      PaneNotificationPlanner.paneHandoffGrace - (beforeBoundary ? .milliseconds(1) : .zero)
    let returned = start.advanced(by: elapsed)
    let expected: [PaneNotification] =
      beforeBoundary ? [] : [notification(in: sessionB, kind: .question)]
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: returned) == expected)
    let completed: [PaneNotification] =
      beforeBoundary
      ? [] : [notification(in: sessionB, kind: .taskCompleted, completion: Self.first)]
    #expect(
      displays(&planner, ["%1": .completed(Self.first)], in: sessionB, at: returned) == completed)
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: returned).isEmpty)
    #expect(displays(&planner, ["%1": .completed(Self.first)], in: sessionB, at: returned).isEmpty)
  }

  @Test("既知の pane が新しい session の基準で plain Unknown なら閾値で1回だけ通知する")
  func knownPaneStartsUnknownTimerAtNewSessionBaseline() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner(settings: Self.withProlongedUnknown)
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .working)], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)

    let joined = start.advanced(by: .seconds(1))
    planner.startObserving(sessionB, at: joined)
    #expect(states(&planner, [pane("%1", .unknown)], in: sessionB, at: joined).isEmpty)
    let deadline = joined.advanced(by: planner.settings.unknownThreshold)
    #expect(planner.nextDeadline == deadline)
    #expect(planner.advance(to: deadline.advanced(by: .milliseconds(-1))).isEmpty)
    #expect(
      planner.advance(to: deadline) == [notification(in: sessionB, kind: .prolongedUnknown)])
    #expect(states(&planner, [pane("%1", .unknown)], in: sessionB, at: deadline).isEmpty)
    #expect(planner.advance(to: deadline.advanced(by: .seconds(1))).isEmpty)
    #expect(planner.nextDeadline == nil)
  }

  @Test("まとめ通知後に猶予内で B に戻った pane は個別に鳴らさず、再びまとめ通知を1回だけ出す")
  func returningSummaryMemberStartsNewSummary() {
    let start = Self.clock.now
    var planner = summarySentWithMissingPane(at: start)
    let returned = start.advanced(by: .seconds(2))

    #expect(
      states(&planner, [pane("%1", .question)], in: sessionB, at: returned)
        == [.attentionSummary(count: 1)])
    #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)
    for seconds in 1...20 {
      let observed = returned.advanced(by: .seconds(seconds))
      #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: observed).isEmpty)
      #expect(displays(&planner, ["%1": .none], in: sessionB, at: observed).isEmpty)
    }
    let later = returned.advanced(by: PaneNotificationPlanner.summaryMaximumDelay)
    #expect(planner.advance(to: later).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: later).isEmpty)
  }

  @Test("まとめ通知後に戻らず猶予を過ぎた pane は B で新しい pane として個別に1回だけ通知する")
  func summaryMemberReturningAfterGraceIsNew() {
    let start = Self.clock.now
    var planner = summarySentWithMissingPane(at: start)
    let missing = start.advanced(by: .seconds(1))
    let returned = missing.advanced(by: PaneNotificationPlanner.paneHandoffGrace + .seconds(1))

    #expect(planner.advance(to: returned).isEmpty)
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionB, at: returned)
        == [notification(in: sessionB, kind: .question)])
    #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)
    let next = returned.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: next).isEmpty)
    let later = returned.advanced(by: PaneNotificationPlanner.summaryMaximumDelay)
    #expect(planner.advance(to: later).isEmpty)
  }

  private func summarySentWithMissingPane(
    at instant: ContinuousClock.Instant
  ) -> PaneNotificationPlanner {
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: instant)
    planner.startObserving(sessionB, at: instant)
    #expect(
      states(&planner, [pane("%1", .question), pane("%2", .permission)], in: sessionA, at: instant)
        .isEmpty)
    #expect(states(&planner, [], in: sessionB, at: instant).isEmpty)
    #expect(displays(&planner, ["%1": .none, "%2": .none], in: sessionA, at: instant).isEmpty)
    #expect(displays(&planner, [:], in: sessionB, at: instant).isEmpty)

    let missing = instant.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%2", .permission)], in: sessionA, at: missing).isEmpty)
    #expect(displays(&planner, ["%2": .none], in: sessionA, at: missing).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: missing) == [.attentionSummary(count: 1)])
    return planner
  }

  private func states(
    _ planner: inout PaneNotificationPlanner, _ panes: [PaneAgentState],
    in session: TerminalSessionKey, at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    planner.observeStates(complete(panes), in: session, at: instant)
  }

  private func displays(
    _ planner: inout PaneNotificationPlanner, _ values: [String: PaneTaskCompletionDisplay],
    in session: TerminalSessionKey, at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    planner.observeCompletions(Self.keyed(values), undetermined: [], in: session, at: instant)
  }

  private func notification(
    in session: TerminalSessionKey, kind: PaneNotificationKind,
    completion: AgentStampedValue? = nil
  ) -> PaneNotification {
    .pane(
      PaneNotificationEvent(
        session: session, paneID: PaneID(rawValue: "%1"), kind: kind, completion: completion))
  }
}
