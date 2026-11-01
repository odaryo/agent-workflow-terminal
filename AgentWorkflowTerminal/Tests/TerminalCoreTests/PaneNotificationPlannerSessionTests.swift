import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知: session ごとの記憶 (設計書 §11.2 / §12.2)")
struct PaneNotificationPlannerSessionTests: PaneNotificationPlannerTesting {
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

  @Test(
    "同じ worktree の B の観測開始と初回観測は A の基準や判断待ちへの遷移を消費しない",
    arguments: [true, false])
  func stateBaselinesAreIndependent(baselineBBeforeTransition: Bool) throws {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(
      planner.observeStates(complete([pane("%1", .working)]), in: sessionA, at: start).isEmpty)
    planner.startObserving(sessionB, at: start)

    if baselineBBeforeTransition {
      #expect(
        planner.observeStates(complete([pane("%2", .permission)]), in: sessionB, at: start)
          .isEmpty)
    }

    let notifications = planner.observeStates(
      complete([pane("%1", .question)]), in: sessionA, at: start)
    #expect(notifications == [notification(in: sessionA, paneID: "%1", kind: .question)])
    let only = try #require(notifications.count == 1 ? notifications.first : nil)
    guard case .pane(let event) = only else {
      Issue.record("判断待ちへの遷移は pane 通知を返す")
      return
    }
    #expect(event.session == sessionA)
    #expect(event.worktree == worktree)
    #expect(event.paneID == PaneID(rawValue: "%1"))

    if !baselineBBeforeTransition {
      #expect(
        planner.observeStates(complete([pane("%2", .permission)]), in: sessionB, at: start)
          .isEmpty)
    }
    #expect(
      planner.observeStates(complete([pane("%2", .permission)]), in: sessionB, at: start)
        .isEmpty)
    #expect(
      planner.observeStates(complete([pane("%1", .question)]), in: sessionA, at: start)
        .isEmpty)
  }

  @Test("A を停止しても B の基準と既知の判断待ちは残り、抜けて再び入ると通知する")
  func stoppingSessionKeepsOtherStateMemory() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    #expect(
      planner.observeStates(complete([pane("%1", .working)]), in: sessionA, at: start).isEmpty)
    #expect(
      planner.observeStates(complete([pane("%2", .working)]), in: sessionB, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
    #expect(
      planner.observeStates(complete([pane("%2", .question)]), in: sessionB, at: start)
        == [notification(in: sessionB, paneID: "%2", kind: .question)])

    planner.stopObserving(sessionA)

    #expect(
      planner.observeStates(complete([pane("%1", .question)]), in: sessionA, at: start)
        .isEmpty)
    #expect(
      planner.observeStates(complete([pane("%2", .question)]), in: sessionB, at: start)
        .isEmpty)
    #expect(
      planner.observeStates(complete([pane("%2", .working)]), in: sessionB, at: start).isEmpty)
    #expect(
      planner.observeStates(complete([pane("%2", .question)]), in: sessionB, at: start)
        == [notification(in: sessionB, paneID: "%2", kind: .question)])
  }

  @Test("まとめ通知は同じ worktree の全 session の基準が揃うまで待つ")
  func summaryWaitsForEveryStartedSession() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)

    #expect(
      planner.observeStates(complete([pane("%1", .question)]), in: sessionA, at: start)
        .isEmpty)
    #expect(planner.observeStates(incomplete([]), in: sessionB, at: start).isEmpty)
    #expect(
      planner.observeStates(complete([pane("%2", .permission)]), in: sessionB, at: start)
        == [.attentionSummary(count: 2)])
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
  }

  @Test("B の初回の完了表示は B の基準で、A の新しい完了 token を消費しない")
  func completionBaselinesAreIndependent() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%1": .none]), undetermined: [], in: sessionA, at: start
      ).isEmpty)
    planner.startObserving(sessionB, at: start)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%2": .completed(Self.first)]), undetermined: [], in: sessionB, at: start
      ).isEmpty)

    #expect(
      planner.observeCompletions(
        Self.keyed(["%1": .completed(Self.first)]), undetermined: [], in: sessionA, at: start
      ) == [notification(in: sessionA, paneID: "%1", kind: .taskCompleted, completion: Self.first)])
    #expect(
      planner.observeCompletions(
        Self.keyed(["%2": .completed(Self.first)]), undetermined: [], in: sessionB, at: start
      ).isEmpty)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%2": .completed(Self.second)]), undetermined: [], in: sessionB, at: start
      ) == [notification(in: sessionB, paneID: "%2", kind: .taskCompleted, completion: Self.second)]
    )
  }

  @Test("A を停止しても B の完了表示の基準と通知済み token は残る")
  func stoppingSessionKeepsOtherCompletionMemory() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%2": .none]), undetermined: [], in: sessionB, at: start
      ).isEmpty)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%2": .completed(Self.first)]), undetermined: [], in: sessionB, at: start
      ) == [notification(in: sessionB, paneID: "%2", kind: .taskCompleted, completion: Self.first)])

    planner.stopObserving(sessionA)

    #expect(
      planner.observeCompletions(
        Self.keyed(["%2": .completed(Self.first)]), undetermined: [], in: sessionB, at: start
      ).isEmpty)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%2": .completed(Self.second)]), undetermined: [], in: sessionB, at: start
      ) == [notification(in: sessionB, paneID: "%2", kind: .taskCompleted, completion: Self.second)]
    )
  }

  @Test(
    "表示中の session の判断待ちだけを抑止し、同じ worktree の別 session とタスク完了は抑止しない",
    arguments: [
      (PaneNotificationKind.question, true), (.permission, true), (.error, true),
      (.attentionUnspecified, true), (.taskCompleted, false), (.prolongedUnknown, false),
    ])
  func suppressionWhileShowingSession(kind: PaneNotificationKind, suppressed: Bool) {
    let completion = kind == .taskCompleted ? Self.first : nil
    let fromA = notification(in: sessionA, paneID: "%1", kind: kind, completion: completion)
    let fromB = notification(in: sessionB, paneID: "%2", kind: kind, completion: completion)

    #expect(fromA.isSuppressed(whileShowing: sessionA) == suppressed)
    #expect(!fromB.isSuppressed(whileShowing: sessionA))
    #expect(fromB.isSuppressed(whileShowing: sessionB) == suppressed)
    #expect(!fromA.isSuppressed(whileShowing: sessionB))
    #expect(!fromA.isSuppressed(whileShowing: Optional<TerminalSessionKey>.none))
    #expect(!PaneNotification.attentionSummary(count: 2).isSuppressed(whileShowing: sessionA))
    #expect(fromB.isSuppressed(whileShowing: worktree) == suppressed)
  }

  @Test("worktree API と primary session API は同じ基準・遷移・完了・停止の記憶を使う")
  func worktreeAPIsSharePrimarySessionMemory() {
    let start = Self.clock.now
    let primary = TerminalSessionKey.primary(worktree)
    var planner = PaneNotificationPlanner()
    planner.startObserving(worktree, at: start)
    #expect(
      planner.observeStates(complete([pane("%1", .working)]), in: primary, at: start).isEmpty)
    let legacyEvent = PaneNotificationEvent(
      worktree: worktree, paneID: PaneID(rawValue: "%1"), kind: .question, completion: nil)
    #expect(legacyEvent.session == primary)
    #expect(
      planner.observeStates(complete([pane("%1", .question)]), in: worktree, at: start)
        == [.pane(legacyEvent)])
    #expect(
      planner.observeStates(complete([pane("%1", .question)]), in: primary, at: start).isEmpty)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%1": .none]), undetermined: [], in: worktree, at: start
      ).isEmpty)
    #expect(
      planner.observeCompletions(
        Self.keyed(["%1": .completed(Self.first)]), undetermined: [], in: primary, at: start
      ) == [event("%1", .taskCompleted, completion: Self.first)])

    planner.stopObserving(worktree)
    #expect(
      planner.observeStates(complete([pane("%1", .permission)]), in: primary, at: start)
        .isEmpty)
    planner.startObserving(primary, at: start)
    #expect(
      planner.observeStates(complete([pane("%1", .working)]), in: worktree, at: start).isEmpty)
    planner.stopObserving(primary)
    #expect(
      planner.observeStates(complete([pane("%1", .permission)]), in: worktree, at: start)
        .isEmpty)
  }

  private func notification(
    in session: TerminalSessionKey, paneID: String, kind: PaneNotificationKind,
    completion: AgentStampedValue? = nil
  ) -> PaneNotification {
    .pane(
      PaneNotificationEvent(
        session: session, paneID: PaneID(rawValue: paneID), kind: kind, completion: completion))
  }
}
