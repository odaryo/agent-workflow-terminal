import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知: 猶予から戻った pane の確認待ち (#508)")
struct PaneNotificationPlannerResumeStateTests: PaneNotificationPlannerTesting {
  let worktree: WorktreeIdentity
  let other: WorktreeIdentity
  let sessionA: TerminalSessionKey
  let sessionB: TerminalSessionKey
  let sessionC: TerminalSessionKey
  let sessionD: TerminalSessionKey

  init() throws {
    let identities = try Self.identities()
    worktree = identities.worktree
    other = identities.other
    sessionA = try #require(TerminalSessionKey(identity: identities.worktree, index: 1))
    sessionB = try #require(TerminalSessionKey(identity: identities.worktree, index: 2))
    sessionC = try #require(TerminalSessionKey(identity: identities.worktree, index: 3))
    sessionD = try #require(TerminalSessionKey(identity: identities.worktree, index: 4))
  }

  @Test("link-window: 2つの session に同時に見えている pane の基準は、lastKnown を上書きしない")
  func linkedPaneBaselineKeepsLastKnown() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .working)], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionA, at: start)
        == [notification(in: sessionA, kind: .question)])

    let joined = start.advanced(by: .seconds(1))
    planner.startObserving(sessionB, at: joined)
    #expect(states(&planner, [pane("%1", .permission)], in: sessionB, at: joined).isEmpty)
    let next = joined.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: next).isEmpty)
  }

  @Test("T2 / T2c: 完了表示だけで戻った pane は無関係なまとめ通知に数えず、印を残して状態の観測後に数える")
  func completionOnlyReturnIsCountedOnlyAfterStates() {
    let start = Self.clock.now
    var planner = summarySent(at: start)
    let returned = start.advanced(by: .seconds(2))
    #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)

    planner.startObserving(sessionD, at: returned)
    #expect(
      states(&planner, [pane("%3", .question)], in: sessionD, at: returned)
        == [.attentionSummary(count: 1)])
    #expect(displays(&planner, ["%3": .none], in: sessionD, at: returned).isEmpty)

    let observed = returned.advanced(by: .seconds(4))
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionB, at: observed)
        == [.attentionSummary(count: 1)])
    #expect(planner.advance(to: observed.advanced(by: .seconds(60))).isEmpty)
  }

  @Test("I1: 最初の基準から plain Unknown の pane が猶予から戻った基準で判断待ちなら、まとめ通知に数える")
  func plainUnknownPaneReturningAsAttentionJoinsSummary() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .unknown)], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
    planner.stopObserving(sessionA)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)

    let resumed = start.advanced(by: .seconds(1))
    planner.startObserving(sessionA, at: resumed)
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionA, at: resumed)
        == [.attentionSummary(count: 1)])
    #expect(planner.advance(to: resumed.advanced(by: .seconds(60))).isEmpty)
  }

  @Test("U1 / U2: 種別不明の注意状態で戻った pane は、既に知らせた判断待ちの続きとしてまとめ通知に数える", arguments: [false, true])
  func returningAsUnspecifiedContinuesSummary(newSession: Bool) {
    let start = Self.clock.now
    var planner = summarySent(at: start)
    let returned = start.advanced(by: .seconds(2))
    let session = newSession ? sessionC : sessionB
    if newSession {
      planner.startObserving(sessionC, at: returned)
    } else {
      #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)
    }
    #expect(
      states(&planner, [attentionUnknown("%1")], in: session, at: returned)
        == [.attentionSummary(count: 1)])
    #expect(planner.advance(to: returned.advanced(by: .seconds(60))).isEmpty)
  }

  @Test("U3: 無効な種類の判断待ちが種別不明の注意状態で戻ったら、まとめ通知に数えず個別に通知する")
  func returningAsUnspecifiedAfterDisabledKindNotifies() {
    let start = Self.clock.now
    let settings = PaneNotificationSettings(
      enabledKinds: PaneNotificationSettings().enabledKinds.subtracting([.question]))
    var planner = summarySent(at: start, settings: settings)
    let returned = start.advanced(by: .seconds(2))
    #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)
    #expect(
      states(&planner, [attentionUnknown("%1")], in: sessionB, at: returned)
        == [notification(in: sessionB, kind: .attentionUnspecified)])
    #expect(planner.advance(to: returned.advanced(by: .seconds(60))).isEmpty)
  }

  @Test("U4: 種別不明の注意状態だった pane が種類の分かる判断待ちで戻ったら、続きとしてまとめ通知に数える")
  func unspecifiedPaneReturningAsQuestionContinuesSummary() {
    let start = Self.clock.now
    var planner = summarySent(at: start, first: attentionUnknown("%1"))
    let returned = start.advanced(by: .seconds(2))
    #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionB, at: returned)
        == [.attentionSummary(count: 1)])
    #expect(planner.advance(to: returned.advanced(by: .seconds(60))).isEmpty)
  }

  // MARK: - 手順

  /// A の %1 (`first`、既定は Question) と %2 (Permission) を基準に取り、%1 が猶予に入った後で
  /// %2 だけのまとめ通知を出した状態。B は空の基準を取っている。
  private func summarySent(
    at instant: ContinuousClock.Instant,
    settings: PaneNotificationSettings = PaneNotificationSettings(),
    first: PaneAgentState? = nil
  ) -> PaneNotificationPlanner {
    var planner = PaneNotificationPlanner(settings: settings)
    planner.startObserving(sessionA, at: instant)
    planner.startObserving(sessionB, at: instant)
    let panes = [first ?? pane("%1", .question), pane("%2", .permission)]
    #expect(states(&planner, panes, in: sessionA, at: instant).isEmpty)
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
    in session: TerminalSessionKey, kind: PaneNotificationKind
  ) -> PaneNotification {
    .pane(
      PaneNotificationEvent(
        session: session, paneID: PaneID(rawValue: "%1"), kind: kind, completion: nil))
  }
}
