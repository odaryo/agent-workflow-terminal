import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知: 猶予から戻った pane のまとめ通知 (#508)")
struct PaneNotificationPlannerResumeTests: PaneNotificationPlannerTesting {
  let worktree: WorktreeIdentity
  let other: WorktreeIdentity
  let sessionA: TerminalSessionKey
  let sessionB: TerminalSessionKey
  let sessionC: TerminalSessionKey

  init() throws {
    let identities = try Self.identities()
    worktree = identities.worktree
    other = identities.other
    sessionA = try #require(TerminalSessionKey(identity: identities.worktree, index: 1))
    sessionB = try #require(TerminalSessionKey(identity: identities.worktree, index: 2))
    sessionC = try #require(TerminalSessionKey(identity: identities.worktree, index: 3))
  }

  @Test("H1: 完了表示が先に戻り、状態が Working なら、まとめ通知も個別の通知も出さない")
  func completionsFirstReturnAsWorkingIsSilent() {
    let start = Self.clock.now
    var planner = summarySentWithMissingPane(at: start)
    let returned = start.advanced(by: .seconds(2))

    var all: [PaneNotification] = []
    all += displays(&planner, ["%1": .none], in: sessionB, at: returned)
    all += planner.setSummaryGate(isOpen: true, at: returned)
    all += states(&planner, [pane("%1", .working)], in: sessionB, at: returned)
    all += planner.setSummaryGate(isOpen: true, at: returned)
    all += completionsOnly(&planner, in: sessionB, from: returned)
    #expect(all.isEmpty)
  }

  @Test("H1p: 完了表示が先に戻り、状態が別の判断待ちなら、まとめ通知を出さず個別に1回だけ通知する")
  func completionsFirstReturnAsOtherAttentionNotifiesOnce() {
    let start = Self.clock.now
    var planner = summarySentWithMissingPane(at: start)
    let returned = start.advanced(by: .seconds(2))

    var all: [PaneNotification] = []
    all += displays(&planner, ["%1": .none], in: sessionB, at: returned)
    all += planner.setSummaryGate(isOpen: true, at: returned)
    all += states(&planner, [pane("%1", .permission)], in: sessionB, at: returned)
    all += planner.setSummaryGate(isOpen: true, at: returned)
    all += completionsOnly(&planner, in: sessionB, from: returned)
    #expect(all == [notification(in: sessionB, kind: .permission)])
  }

  @Test(
    "完了表示が先に戻っても、まとめ通知は状態を観測してから同じ判断待ち・plain Unknown で1回だけ出す",
    arguments: [AgentState.question, .unknown])
  func completionsFirstReturnRestartsSummaryOnlyAfterStates(state: AgentState) {
    let start = Self.clock.now
    var planner = summarySentWithMissingPane(at: start)
    let returned = start.advanced(by: .seconds(2))

    #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: returned).isEmpty)
    #expect(
      states(&planner, [pane("%1", state)], in: sessionB, at: returned)
        == [.attentionSummary(count: 1)])
    #expect(planner.setSummaryGate(isOpen: true, at: returned).isEmpty)
    #expect(completionsOnly(&planner, in: sessionB, from: returned).isEmpty)
  }

  @Test(
    "H2 / W1: 新しいタブ C の基準に戻った pane は、その観測を遷移として扱う",
    arguments: [AgentState.question, .working, .permission])
  func newSessionBaselineIsTransition(baseline: AgentState) {
    let start = Self.clock.now
    var planner = summarySentWithMissingPane(at: start)
    let returned = start.advanced(by: .seconds(2))
    var all = joinNewSession(&planner, state: baseline, at: returned)
    all += change(&planner, after: baseline, in: sessionC, from: returned)
    #expect(all == expected(after: baseline, in: sessionC))
  }

  @Test(
    "H6 / W2: gate が開く前に停止して再開した session の基準は、その観測を遷移として扱う",
    arguments: [AgentState.question, .working, .permission])
  func restartedSessionBaselineIsTransition(baseline: AgentState) {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    var all = restartBeforeGate(&planner, state: baseline, at: start)
    all += change(&planner, after: baseline, in: sessionA, from: start.advanced(by: .seconds(1)))
    #expect(all == expected(after: baseline, in: sessionA))
  }

  @Test("A2: まとめ通知が進んでいる間に戻った pane は、まとめ通知の開始時刻を後ろへずらさない")
  func returningPaneKeepsPendingSummaryStart() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    #expect(
      states(&planner, [pane("%1", .question), pane("%2", .question)], in: sessionA, at: start)
        .isEmpty)
    #expect(states(&planner, [], in: sessionB, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none, "%2": .none], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, [:], in: sessionB, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: false, at: start).isEmpty)

    let missing = start.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%2", .question)], in: sessionA, at: missing).isEmpty)
    #expect(displays(&planner, ["%2": .none], in: sessionA, at: missing).isEmpty)
    #expect(planner.setSummaryGate(isOpen: false, at: missing).isEmpty)

    let returned = start.advanced(by: .seconds(5))
    #expect(displays(&planner, ["%1": .none], in: sessionB, at: returned).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: returned).isEmpty)
    #expect(planner.setSummaryGate(isOpen: false, at: returned).isEmpty)

    let deadline = start.advanced(by: PaneNotificationPlanner.summaryMaximumDelay)
    #expect(planner.nextDeadline == deadline)
    #expect(planner.advance(to: deadline.advanced(by: .milliseconds(-1))).isEmpty)
    #expect(planner.advance(to: deadline) == [.attentionSummary(count: 2)])
  }

  @Test("最初の基準から plain Unknown の pane が別の session の基準に現れても、Unknown の計時を始め直さない")
  func plainUnknownSinceFirstBaselineKeepsTimerInOtherSessionBaseline() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner(settings: Self.withProlongedUnknown)
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .unknown)], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)

    let joined = start.advanced(by: .seconds(1))
    planner.startObserving(sessionB, at: joined)
    #expect(states(&planner, [pane("%1", .unknown)], in: sessionB, at: joined).isEmpty)
    let deadline = start.advanced(by: planner.settings.unknownThreshold)
    #expect(planner.nextDeadline == deadline)
    #expect(planner.advance(to: deadline.advanced(by: .milliseconds(-1))).isEmpty)
    #expect(
      planner.advance(to: deadline) == [notification(in: sessionB, kind: .prolongedUnknown)])
  }

  // MARK: - 手順

  /// A の %1 (Question) と %2 (Permission) を基準に取り、%1 が猶予に入った後で %2 だけの
  /// まとめ通知を出した状態。B は空の基準を取っている。
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

  /// アプリは入力のたびに `setSummaryGate` を呼ぶ。その戻り値も含めて集める。
  private func joinNewSession(
    _ planner: inout PaneNotificationPlanner, state: AgentState,
    at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    planner.startObserving(sessionC, at: instant)
    var all = planner.setSummaryGate(isOpen: true, at: instant)
    all += states(&planner, [pane("%1", state)], in: sessionC, at: instant)
    all += planner.setSummaryGate(isOpen: true, at: instant)
    all += displays(&planner, ["%1": .none], in: sessionC, at: instant)
    all += planner.setSummaryGate(isOpen: true, at: instant)
    all += completionsOnly(&planner, in: sessionC, from: instant)
    return all
  }

  /// gate が閉じている間に A を停止して再開する。停止の直後の `setSummaryGate` で、猶予中の
  /// pane しか居ないまとめ通知の開始時刻が消える。
  private func restartBeforeGate(
    _ planner: inout PaneNotificationPlanner, state: AgentState,
    at start: ContinuousClock.Instant
  ) -> [PaneNotification] {
    planner.startObserving(sessionA, at: start)
    var all = planner.setSummaryGate(isOpen: false, at: start)
    all += states(&planner, [pane("%1", .question)], in: sessionA, at: start)
    all += planner.setSummaryGate(isOpen: false, at: start)
    all += displays(&planner, ["%1": .none], in: sessionA, at: start)
    all += planner.setSummaryGate(isOpen: false, at: start)
    planner.stopObserving(sessionA)
    all += planner.setSummaryGate(isOpen: false, at: start)

    let resumed = start.advanced(by: .seconds(1))
    planner.startObserving(sessionA, at: resumed)
    all += planner.setSummaryGate(isOpen: false, at: resumed)
    all += displays(&planner, ["%1": .none], in: sessionA, at: resumed)
    all += planner.setSummaryGate(isOpen: false, at: resumed)
    all += states(&planner, [pane("%1", state)], in: sessionA, at: resumed)
    all += planner.setSummaryGate(isOpen: false, at: resumed)
    all += planner.setSummaryGate(isOpen: true, at: resumed)
    all += completionsOnly(&planner, in: sessionA, from: resumed)
    return all
  }

  /// アプリは状態が変わらない限り同じ観測を配信しない (`AgentAdapter.observations` と
  /// `WorktreePaneAgentStateFeed.yieldIfChanged`)。戻った後は完了表示だけが2秒ごとに届く。
  private func completionsOnly(
    _ planner: inout PaneNotificationPlanner, in session: TerminalSessionKey,
    from instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    var all: [PaneNotification] = []
    for step in 1...30 {
      let observed = instant.advanced(by: .seconds(2 * step))
      all += displays(&planner, ["%1": .none], in: session, at: observed)
      all += planner.advance(to: observed)
      all += planner.setSummaryGate(isOpen: true, at: observed)
    }
    return all
  }

  /// 完了表示だけの期間の後に状態を変える。Working は直接 Question へ (W1 / W2)、Permission は
  /// Working を経て Question へ移す。
  private func change(
    _ planner: inout PaneNotificationPlanner, after baseline: AgentState,
    in session: TerminalSessionKey, from instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    let next: [AgentState] =
      switch baseline {
      case .working: [.question]
      case .permission: [.working, .question]
      default: []
      }
    var all: [PaneNotification] = []
    for (offset, state) in next.enumerated() {
      let observed = instant.advanced(by: .seconds(61 + 2 * offset))
      all += states(&planner, [pane("%1", state)], in: session, at: observed)
      all += planner.setSummaryGate(isOpen: true, at: observed)
    }
    return all + planner.advance(to: instant.advanced(by: .seconds(120)))
  }

  private func expected(
    after baseline: AgentState, in session: TerminalSessionKey
  ) -> [PaneNotification] {
    switch baseline {
    case .working: [notification(in: session, kind: .question)]
    case .permission:
      [notification(in: session, kind: .permission), notification(in: session, kind: .question)]
    default: [.attentionSummary(count: 1)]
    }
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
