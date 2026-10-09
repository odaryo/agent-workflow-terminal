import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知の判定 (設計書 §11.2)")
struct PaneNotificationPlannerTests: PaneNotificationPlannerTesting {
  let worktree: WorktreeIdentity
  let other: WorktreeIdentity

  init() throws {
    (worktree, other) = try Self.identities()
  }

  // MARK: - 起動直後の基準

  @Test("adapter の結果が揃う前の空の yield を基準にせず、揃った観測の判断待ちをまとめて1件にする")
  func startupSummaryIgnoresEmptyFirstYield() {
    let start = Self.clock.now
    var planner = started()

    // feed の最初の yield は adapter の結果がまだ無いので `[]` になる (#387)。
    #expect(planner.observeStates(incomplete([]), in: worktree, at: start).isEmpty)
    #expect(
      planner.observeStates(incomplete([pane("%1", .question)]), in: worktree, at: start)
        .isEmpty)
    let settled = planner.observeStates(
      complete([pane("%1", .question), pane("%2", .permission), pane("%3", .working)]),
      in: worktree, at: start)
    #expect(settled.isEmpty)

    #expect(planner.setSummaryGate(isOpen: true, at: start) == [.attentionSummary(count: 2)])
    // まとめた pane は、状態に留まっている間は個別にも鳴らない。
    #expect(
      planner.observeStates(
        complete([pane("%1", .question), pane("%2", .permission), pane("%3", .working)]),
        in: worktree, at: start
      ).isEmpty)
  }

  @Test("起動直後に判断待ちが無ければ、まとめ通知を出さない")
  func noSummaryWithoutAttention() {
    let start = Self.clock.now
    var planner = started()
    _ = planner.observeStates(incomplete([]), in: worktree, at: start)
    _ = planner.observeStates(complete([pane("%1", .working)]), in: worktree, at: start)

    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
  }

  @Test("基準を取れていない worktree が残る間はまとめ通知を待ち、全部そろったら1件にする")
  func summaryWaitsForEveryStartedWorktree() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(worktree, at: start)
    planner.startObserving(other, at: start)
    _ = planner.setSummaryGate(isOpen: true, at: start)

    #expect(
      planner.observeStates(complete([pane("%1", .question)]), in: worktree, at: start)
        .isEmpty)
    #expect(planner.observeStates(incomplete([]), in: other, at: start).isEmpty)

    #expect(
      planner.observeStates(complete([pane("%2", .error)]), in: other, at: start)
        == [.attentionSummary(count: 2)])
  }

  @Test("基準を取れない worktree が残っても、最初の候補から上限時間でまとめ通知を出す")
  func summaryIsFlushedAfterMaximumDelay() throws {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()
    planner.startObserving(worktree, at: start)
    planner.startObserving(other, at: start)
    _ = planner.setSummaryGate(isOpen: true, at: start)
    _ = planner.observeStates(complete([pane("%1", .question)]), in: worktree, at: start)

    let deadline = try #require(planner.nextDeadline)
    #expect(deadline == start.advanced(by: PaneNotificationPlanner.summaryMaximumDelay))
    #expect(planner.advance(to: deadline) == [.attentionSummary(count: 1)])
    #expect(planner.nextDeadline == nil)
  }

  @Test("まとめ通知を出す前に判断待ちを抜けた pane は数えない")
  func summaryCountsOnlyPanesStillWaiting() {
    let start = Self.clock.now
    var planner = started()
    _ = planner.observeStates(
      complete([pane("%1", .question), pane("%2", .permission)]), in: worktree, at: start)
    _ = planner.observeStates(
      complete([pane("%1", .working), pane("%2", .permission)]), in: worktree, at: start)

    #expect(planner.setSummaryGate(isOpen: true, at: start) == [.attentionSummary(count: 1)])
  }

  @Test("起動直後の判断待ちが全部抜けていれば、まとめ通知は出ない")
  func emptySummaryIsDropped() {
    let start = Self.clock.now
    var planner = started()
    _ = planner.observeStates(complete([pane("%1", .question)]), in: worktree, at: start)
    _ = planner.observeStates(complete([pane("%1", .working)]), in: worktree, at: start)

    #expect(planner.setSummaryGate(isOpen: true, at: start).isEmpty)
  }

  @Test("まとめ通知は無効にした種類を数えない")
  func summaryRespectsSettings() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner(
      settings: PaneNotificationSettings(enabledKinds: [.permission]))
    planner.startObserving(worktree, at: start)
    _ = planner.observeStates(
      complete([pane("%1", .question), pane("%2", .permission)]), in: worktree, at: start)

    #expect(planner.setSummaryGate(isOpen: true, at: start) == [.attentionSummary(count: 1)])
  }

  @Test("基準の後に Active 化した worktree は、その worktree だけのまとめ通知になる")
  func laterActivationGetsItsOwnSummary() {
    let start = Self.clock.now
    var planner = started()
    _ = planner.observeStates(complete([pane("%1", .question)]), in: worktree, at: start)
    #expect(planner.setSummaryGate(isOpen: true, at: start) == [.attentionSummary(count: 1)])

    planner.startObserving(other, at: start)
    #expect(planner.observeStates(incomplete([]), in: other, at: start).isEmpty)
    #expect(
      planner.observeStates(complete([pane("%2", .permission)]), in: other, at: start)
        == [.attentionSummary(count: 1)])
  }

  // MARK: - 判断待ちの遷移

  @Test("判断待ちへ入った遷移1回につき1回だけ通知し、留まっている間は再通知しない")
  func notifiesOncePerTransition() {
    var planner = baselined([pane("%1", .working)])

    #expect(observe(&planner, [pane("%1", .permission)]) == [event("%1", .permission)])
    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
  }

  @Test("一度抜けて再び入れば、新しく通知する")
  func notifiesAgainAfterLeaving() {
    var planner = baselined([pane("%1", .question)])

    _ = observe(&planner, [pane("%1", .working)])

    #expect(observe(&planner, [pane("%1", .question)]) == [event("%1", .question)])
  }

  @Test(
    "判断待ちの種類が変われば、新しい遷移として通知する",
    arguments: [
      (AgentState.question, AgentState.permission), (.permission, .error), (.error, .question),
    ])
  func notifiesOnKindChange(from: AgentState, to: AgentState) throws {
    var planner = baselined([pane("%1", .working)])
    _ = observe(&planner, [pane("%1", from)])

    let kind = try #require(PaneNotificationKind(attention: to))
    #expect(observe(&planner, [pane("%1", to)]) == [event("%1", kind)])
  }

  @Test("Unknown や観測なしを挟んでも、直前の既知の状態から判定する")
  func unknownAndMissingKeepLastKnownState() {
    var planner = baselined([pane("%1", .working)])
    _ = observe(&planner, [pane("%1", .question)])

    #expect(observe(&planner, [pane("%1", .unknown)]).isEmpty)
    #expect(observe(&planner, [pane("%1", .question)]).isEmpty)
    // Agent が `.absent` になった回は feed の出力から pane が消える。
    #expect(observe(&planner, []).isEmpty)
    #expect(observe(&planner, [pane("%1", .question)]).isEmpty)
  }

  @Test("Working から Unknown を挟んで判断待ちに入れば、通知する")
  func unknownBetweenWorkingAndAttention() {
    var planner = baselined([pane("%1", .working)])
    _ = observe(&planner, [pane("%1", .unknown)])

    #expect(observe(&planner, [pane("%1", .error)]) == [event("%1", .error)])
  }

  @Test("応答終了 (Completed) と Idle と Working では通知しない")
  func turnEndIsNotNotified() {
    var planner = baselined([pane("%1", .working)])

    #expect(observe(&planner, [pane("%1", .completed)]).isEmpty)
    #expect(observe(&planner, [pane("%1", .idle)]).isEmpty)
    #expect(observe(&planner, [pane("%1", .working)]).isEmpty)
  }

  @Test("無効にした種類は通知しないが、遷移は消費する (後で有効にしても遡って鳴らない)")
  func disabledKindConsumesTransition() {
    var planner = baselined(
      [pane("%1", .working)],
      settings: PaneNotificationSettings(enabledKinds: [.question, .error, .taskCompleted]))

    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
    planner.settings = PaneNotificationSettings()
    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
  }

  @Test("基準の後に現れた pane が最初から判断待ちなら通知する (trust prompt 等、§12.8)")
  func newPaneInAttentionIsNotified() {
    var planner = baselined([pane("%1", .working)])

    #expect(
      observe(&planner, [pane("%1", .working), pane("%2", .permission)])
        == [event("%2", .permission)])
  }

  @Test("基準の時点で Agent が居なかった pane も、後から起動して判断待ちに入れば1回通知する")
  func agentStartedAfterBaselineIsNotified() {
    var planner = baselined([])

    #expect(observe(&planner, [pane("%1", .idle)]).isEmpty)
    #expect(observe(&planner, [pane("%1", .working)]).isEmpty)
    #expect(observe(&planner, [pane("%1", .permission)]) == [event("%1", .permission)])
    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
  }

  @Test("種別不明の注意状態 (Unknown + Needs Attention、§12.4.3) は入った遷移で1回通知する")
  func unspecifiedAttentionIsNotified() {
    var planner = baselined([pane("%1", .working)])

    #expect(observe(&planner, [attentionUnknown("%1")]) == [event("%1", .attentionUnspecified)])
    #expect(observe(&planner, [attentionUnknown("%1")]).isEmpty)
  }

  @Test("種別不明の注意状態と、種類の分かる判断待ちの間の行き来は同じ判断待ちとして再通知しない")
  func unspecifiedAndSpecificAttentionAreOneEpisode() {
    var planner = baselined([pane("%1", .working)])
    _ = observe(&planner, [attentionUnknown("%1")])

    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
    #expect(observe(&planner, [attentionUnknown("%1")]).isEmpty)
    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
    // 種類の分かる状態どうしの変化は、間に種別不明を挟んでも新しい遷移。
    #expect(observe(&planner, [pane("%1", .question)]) == [event("%1", .question)])
  }

  @Test("種別不明を無効にしていても、その後に入った有効な種類の判断待ちは通知する (S1)")
  func disabledUnspecifiedDoesNotSwallowEnabledKind() {
    var planner = baselined([pane("%1", .working)], settings: Self.withoutUnspecified)

    #expect(observe(&planner, [attentionUnknown("%1")]).isEmpty)
    #expect(observe(&planner, [pane("%1", .permission)]) == [event("%1", .permission)])
    // 知らせた後は、種別不明との行き来を続きとして扱う。
    #expect(observe(&planner, [attentionUnknown("%1")]).isEmpty)
    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
  }

  @Test("基準の時点の種別不明が無効な種類なら、その後の有効な種類の判断待ちを通知する (S1b)")
  func disabledUnspecifiedAtBaselineDoesNotSwallowEnabledKind() {
    var planner = baselined([attentionUnknown("%1")], settings: Self.withoutUnspecified)

    #expect(observe(&planner, [pane("%1", .permission)]) == [event("%1", .permission)])
  }

  @Test("基準の時点の種別不明が有効な種類なら、まとめ通知で知らせたので後の種類の判明は続き")
  func enabledUnspecifiedAtBaselineIsContinued() {
    var planner = baselined([attentionUnknown("%1")])

    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
  }

  @Test("無効な種類の判断待ちが種別不明に移ったら、種別不明として通知する")
  func disabledKindDoesNotSwallowUnspecified() {
    let settings = PaneNotificationSettings(
      enabledKinds: PaneNotificationSettings().enabledKinds.subtracting([.question]))
    var planner = baselined([pane("%1", .working)], settings: settings)

    #expect(observe(&planner, [pane("%1", .question)]).isEmpty)
    #expect(observe(&planner, [attentionUnknown("%1")]) == [event("%1", .attentionUnspecified)])
    #expect(observe(&planner, [pane("%1", .question)]).isEmpty)
  }

  @Test("知らせた判断待ちは、後から種別不明を無効にしても続きのまま (設定は遡らない)")
  func announcedEpisodeSurvivesDisabling() {
    var planner = baselined([pane("%1", .working)])
    _ = observe(&planner, [attentionUnknown("%1")])
    planner.settings = Self.withoutUnspecified

    #expect(observe(&planner, [pane("%1", .permission)]).isEmpty)
  }

  @Test("知らせなかった判断待ちは、後から有効にしても遡って鳴らさず、有効な種類へ移ったら鳴らす")
  func unannouncedEpisodeAfterEnabling() {
    var planner = baselined([pane("%1", .working)], settings: Self.withoutUnspecified)
    _ = observe(&planner, [attentionUnknown("%1")])
    planner.settings = PaneNotificationSettings()

    #expect(observe(&planner, [attentionUnknown("%1")]).isEmpty)
    #expect(observe(&planner, [pane("%1", .permission)]) == [event("%1", .permission)])
  }

  @Test("基準より前の観測では、判断待ちへの遷移があっても通知しない")
  func nothingBeforeBaseline() {
    let start = Self.clock.now
    var planner = started()

    #expect(
      planner.observeStates(incomplete([pane("%1", .working)]), in: worktree, at: start)
        .isEmpty)
    #expect(
      planner.observeStates(incomplete([pane("%1", .question)]), in: worktree, at: start)
        .isEmpty)
  }

  // MARK: - 記憶の破棄

  @Test("観測を止めた worktree の記憶を捨て、再開したら新しい基準を取る")
  func stopForgetsWorktree() {
    let start = Self.clock.now
    var planner = baselined([pane("%1", .question)])
    _ = planner.setSummaryGate(isOpen: true, at: start)

    planner.stopObserving(worktree)
    #expect(
      planner.observeStates(complete([pane("%1", .permission)]), in: worktree, at: start)
        .isEmpty)

    planner.startObserving(worktree, at: start)
    #expect(
      planner.observeStates(complete([pane("%1", .permission)]), in: worktree, at: start)
        == [.attentionSummary(count: 1)])
  }

  @Test("pane 一覧からも状態からも消えた pane の記憶を捨てる")
  func vanishedPaneIsForgotten() {
    var planner = baselined([pane("%1", .question)])
    _ = completions(&planner, ["%1": .completed(Self.first)])

    _ = observe(&planner, [])
    _ = completions(&planner, [:])

    #expect(observe(&planner, [pane("%1", .question)]) == [event("%1", .question)])
  }

  @Test("概要の読み取りに無くても、状態の観測に残っている pane の記憶は保つ")
  func paneStillObservedIsKept() {
    var planner = baselined([pane("%1", .question)])

    _ = completions(&planner, [:])

    #expect(observe(&planner, [pane("%1", .question)]).isEmpty)
  }

  @Test("観測を始めていない worktree の入力は無視する")
  func unknownWorktreeIsIgnored() {
    let start = Self.clock.now
    var planner = PaneNotificationPlanner()

    #expect(
      planner.observeStates(complete([pane("%1", .question)]), in: worktree, at: start)
        .isEmpty)
    #expect(
      planner.observeCompletions(
        [PaneID(rawValue: "%1"): .completed(Self.first)], undetermined: [], in: worktree, at: start
      ).isEmpty)
  }

  // MARK: - 設定と前面時の抑止

  @Test("既定は Question / Permission / Error / 種別不明 / タスク完了が ON、長時間 Unknown が OFF で10分")
  func defaultSettings() {
    let settings = PaneNotificationSettings()

    #expect(
      settings.enabledKinds
        == [.question, .permission, .error, .attentionUnspecified, .taskCompleted])
    #expect(settings.unknownThreshold == .seconds(600))
  }

  @Test(
    "表示中の worktree の判断待ちは抑止し、タスク完了と他の worktree は抑止しない",
    arguments: [
      (PaneNotificationKind.question, true), (.permission, true), (.error, true),
      (.attentionUnspecified, true), (.taskCompleted, false), (.prolongedUnknown, false),
    ])
  func suppressionWhileShowing(kind: PaneNotificationKind, suppressed: Bool) {
    let notification = PaneNotification.pane(
      PaneNotificationEvent(
        worktree: worktree, paneID: PaneID(rawValue: "%1"), kind: kind,
        completion: kind == .taskCompleted ? Self.first : nil))

    #expect(notification.isSuppressed(whileShowing: worktree) == suppressed)
    #expect(!notification.isSuppressed(whileShowing: other))
    #expect(!notification.isSuppressed(whileShowing: nil))
    #expect(!PaneNotification.attentionSummary(count: 1).isSuppressed(whileShowing: worktree))
  }
}
