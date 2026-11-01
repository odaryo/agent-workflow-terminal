import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知: session 間の pane の引き継ぎ (#494)")
struct PaneNotificationPlannerHandoffTests: PaneNotificationPlannerTesting {
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

  @Test("m2 / m2b: 移動先で状態と完了のどちらを先に観測しても再通知しない", arguments: [true, false])
  func movedPaneKeepsAnnouncedAttentionAndToken(completionsFirst: Bool) {
    let start = Self.clock.now
    var planner = twoSessions(at: start, panesA: [pane("%2", .working)])
    #expect(
      states(&planner, [pane("%2", .question)], in: sessionA, at: start)
        == [notification(in: sessionA, paneID: "%2", kind: .question)])
    #expect(
      displays(&planner, ["%2": .completed(Self.first)], in: sessionA, at: start)
        == [notification(in: sessionA, paneID: "%2", kind: .taskCompleted, completion: Self.first)])

    let moved = start.advanced(by: .seconds(1))
    #expect(states(&planner, [], in: sessionA, at: moved).isEmpty)
    #expect(displays(&planner, [:], in: sessionA, at: moved).isEmpty)
    if completionsFirst {
      #expect(displays(&planner, ["%2": .completed(Self.first)], in: sessionB, at: moved).isEmpty)
      #expect(states(&planner, [pane("%2", .question)], in: sessionB, at: moved).isEmpty)
    } else {
      #expect(states(&planner, [pane("%2", .question)], in: sessionB, at: moved).isEmpty)
      #expect(displays(&planner, ["%2": .completed(Self.first)], in: sessionB, at: moved).isEmpty)
    }
    #expect(states(&planner, [pane("%2", .question)], in: sessionB, at: moved).isEmpty)
    #expect(displays(&planner, ["%2": .completed(Self.first)], in: sessionB, at: moved).isEmpty)
    #expect(
      displays(&planner, ["%2": .completed(Self.second)], in: sessionB, at: moved)
        == [notification(in: sessionB, paneID: "%2", kind: .taskCompleted, completion: Self.second)]
    )
  }

  @Test("m3: 同じ pane を A と B で観測しても判断待ちは1回だけで、A の停止後も再通知しない")
  func linkedPaneSurvivesStoppingOriginalSession() {
    let start = Self.clock.now
    var planner = twoSessions(at: start, panesA: [pane("%1", .working)])
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionA, at: start)
        == [notification(in: sessionA, paneID: "%1", kind: .question)])
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: start).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: start).isEmpty)

    planner.stopObserving(sessionA)

    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: start).isEmpty)
    let later = start.advanced(by: PaneNotificationPlanner.paneHandoffGrace + .seconds(1))
    #expect(planner.advance(to: later).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: later).isEmpty)
  }

  @Test(
    "m3b: 後から始めた B の基準は既知の状態・通知済み記録を保ち、まとめ通知に数えない",
    arguments: [
      (true, AgentState.question), (false, .question), (true, .unknown), (false, .unknown),
    ])
  func laterBaselinePreservesExistingMemory(duringGrace: Bool, baselineState: AgentState) {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    #expect(states(&planner, [pane("%1", .working)], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionA, at: start)
        == [notification(in: sessionA, paneID: "%1", kind: .question)])
    #expect(
      displays(&planner, ["%1": .completed(Self.first)], in: sessionA, at: start)
        == [notification(in: sessionA, paneID: "%1", kind: .taskCompleted, completion: Self.first)])
    if duringGrace {
      #expect(states(&planner, [], in: sessionA, at: start).isEmpty)
      #expect(displays(&planner, [:], in: sessionA, at: start).isEmpty)
    }

    let joined = start.advanced(by: .seconds(1))
    planner.startObserving(sessionB, at: joined)
    #expect(states(&planner, [pane("%1", baselineState)], in: sessionB, at: joined).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionB, at: joined).isEmpty)
    #expect(displays(&planner, ["%1": .completed(Self.first)], in: sessionB, at: joined).isEmpty)
    #expect(states(&planner, [attentionUnknown("%1")], in: sessionB, at: joined).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionB, at: joined).isEmpty)
    #expect(
      planner.advance(to: joined.advanced(by: PaneNotificationPlanner.summaryMaximumDelay)).isEmpty)
  }

  @Test("m4: 移動後の B の Unknown の計時は A の観測なしで切れず、B で1回だけ通知する")
  func movedUnknownTimerBelongsToDestination() {
    let start = Self.clock.now
    var planner = twoSessions(
      at: start, panesA: [pane("%2", .working)], settings: Self.withProlongedUnknown)
    let moved = start.advanced(by: .seconds(1))
    #expect(states(&planner, [pane("%2", .unknown)], in: sessionB, at: moved).isEmpty)
    let deadline = moved.advanced(by: planner.settings.unknownThreshold)
    #expect(planner.nextDeadline == deadline)
    for seconds in [2, 4, 8] {
      let instant = start.advanced(by: .seconds(seconds))
      #expect(states(&planner, [], in: sessionA, at: instant).isEmpty)
      #expect(displays(&planner, [:], in: sessionA, at: instant).isEmpty)
      #expect(planner.nextDeadline == deadline)
    }

    #expect(
      planner.advance(to: deadline)
        == [notification(in: sessionB, paneID: "%2", kind: .prolongedUnknown)])
    #expect(planner.advance(to: deadline.advanced(by: .seconds(1))).isEmpty)
    #expect(planner.nextDeadline == nil)
  }

  @Test("猶予を過ぎてもどこにも現れなかった pane ID は新しい pane として通知する")
  func paneReturningAfterGraceIsNew() {
    let start = Self.clock.now
    #expect(PaneNotificationPlanner.paneHandoffGrace == .seconds(10))
    var planner = twoSessions(at: start, panesA: [pane("%3", .working)])
    #expect(
      states(&planner, [pane("%3", .question)], in: sessionA, at: start)
        == [notification(in: sessionA, paneID: "%3", kind: .question)])
    #expect(states(&planner, [], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, [:], in: sessionA, at: start).isEmpty)

    let returned = start.advanced(by: PaneNotificationPlanner.paneHandoffGrace + .seconds(1))
    #expect(planner.advance(to: returned).isEmpty)
    #expect(
      states(&planner, [pane("%3", .question)], in: sessionB, at: returned)
        == [notification(in: sessionB, paneID: "%3", kind: .question)])
    #expect(states(&planner, [pane("%3", .question)], in: sessionB, at: returned).isEmpty)
  }

  @Test("停止後に猶予内で再開した session の基準は通知済みの判断待ちを鳴らし直さない")
  func restartingWithinGraceKeepsAttentionMemory() {
    let start = Self.clock.now
    var planner = twoSessions(at: start, panesA: [pane("%1", .working)])
    #expect(
      states(&planner, [pane("%1", .question)], in: sessionA, at: start)
        == [notification(in: sessionA, paneID: "%1", kind: .question)])
    planner.stopObserving(sessionA)

    let resumed = start.advanced(by: .seconds(1))
    planner.startObserving(sessionA, at: resumed)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: resumed).isEmpty)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: resumed).isEmpty)
  }

  @Test("猶予中の pane はまとめ通知に数えず、観測中の判断待ちだけを数える", arguments: [true, false])
  func summaryExcludesPaneDuringGrace(stopSession: Bool) {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(sessionA, at: start)
    planner.startObserving(sessionB, at: start)
    #expect(states(&planner, [pane("%1", .question)], in: sessionA, at: start).isEmpty)
    #expect(states(&planner, [pane("%2", .permission)], in: sessionB, at: start).isEmpty)
    #expect(displays(&planner, ["%1": .none], in: sessionA, at: start).isEmpty)
    #expect(displays(&planner, ["%2": .none], in: sessionB, at: start).isEmpty)

    let missing = start.advanced(by: .seconds(1))
    if stopSession {
      planner.stopObserving(sessionA)
    } else {
      #expect(states(&planner, [], in: sessionA, at: missing).isEmpty)
      #expect(displays(&planner, [:], in: sessionA, at: missing).isEmpty)
    }
    #expect(planner.setSummaryGate(isOpen: true, at: missing) == [.attentionSummary(count: 1)])
  }

  @Test("猶予中は Unknown の期限から外し、再観測した時点から継続時間を測り直す", arguments: [true, false])
  func unknownTimerIsInterruptedDuringGrace(stopSession: Bool) {
    let start = Self.clock.now
    let settings = PaneNotificationSettings(
      enabledKinds: Self.withProlongedUnknown.enabledKinds, unknownThreshold: .seconds(2))
    var planner = twoSessions(at: start, panesA: [pane("%2", .unknown)], settings: settings)
    let oldDeadline = start.advanced(by: .seconds(2))
    #expect(planner.nextDeadline == oldDeadline)
    let missing = start.advanced(by: .seconds(1))
    if stopSession {
      #expect(planner.advance(to: missing).isEmpty)
      planner.stopObserving(sessionA)
    } else {
      #expect(states(&planner, [], in: sessionA, at: missing).isEmpty)
      #expect(displays(&planner, [:], in: sessionA, at: missing).isEmpty)
    }
    #expect(planner.nextDeadline != oldDeadline)
    #expect(planner.advance(to: oldDeadline).isEmpty)

    let returned = start.advanced(by: .seconds(3))
    #expect(states(&planner, [pane("%2", .unknown)], in: sessionB, at: returned).isEmpty)
    let newDeadline = returned.advanced(by: settings.unknownThreshold)
    #expect(planner.nextDeadline == newDeadline)
    #expect(
      planner.advance(to: newDeadline)
        == [notification(in: sessionB, paneID: "%2", kind: .prolongedUnknown)])
  }

  @Test("完了表示だけで B に付け替えても、長時間 Unknown と新しい遷移は B で通知する")
  func completionObservationTransfersSession() {
    let start = Self.clock.now
    var planner = twoSessions(
      at: start, panesA: [pane("%2", .unknown)], settings: Self.withProlongedUnknown)
    #expect(displays(&planner, ["%2": .none], in: sessionB, at: start).isEmpty)
    planner.stopObserving(sessionA)
    #expect(
      displays(&planner, ["%2": .completed(Self.first)], in: sessionB, at: start)
        == [notification(in: sessionB, paneID: "%2", kind: .taskCompleted, completion: Self.first)])
    let deadline = start.advanced(by: planner.settings.unknownThreshold)
    #expect(planner.nextDeadline == deadline)
    #expect(
      planner.advance(to: deadline)
        == [notification(in: sessionB, paneID: "%2", kind: .prolongedUnknown)])
    #expect(
      states(&planner, [pane("%2", .question)], in: sessionB, at: deadline)
        == [notification(in: sessionB, paneID: "%2", kind: .question)])
  }

  private func twoSessions(
    at instant: ContinuousClock.Instant, panesA: [PaneAgentState],
    settings: PaneNotificationSettings = PaneNotificationSettings()
  ) -> PaneNotificationPlanner {
    var planner = PaneNotificationPlanner(settings: settings)
    planner.startObserving(sessionA, at: instant)
    planner.startObserving(sessionB, at: instant)
    #expect(states(&planner, panesA, in: sessionA, at: instant).isEmpty)
    #expect(states(&planner, [], in: sessionB, at: instant).isEmpty)
    let initialDisplays = Dictionary(
      uniqueKeysWithValues: panesA.map { ($0.id, PaneTaskCompletionDisplay.none) })
    #expect(
      planner.observeCompletions(initialDisplays, undetermined: [], in: sessionA, at: instant)
        .isEmpty)
    #expect(displays(&planner, [:], in: sessionB, at: instant).isEmpty)
    #expect(planner.setSummaryGate(isOpen: true, at: instant).isEmpty)
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
    in session: TerminalSessionKey, paneID: String, kind: PaneNotificationKind,
    completion: AgentStampedValue? = nil
  ) -> PaneNotification {
    .pane(
      PaneNotificationEvent(
        session: session, paneID: PaneID(rawValue: paneID), kind: kind, completion: completion))
  }
}
