import Foundation
import TerminalCore
import Testing

@Suite("Mac のローカル通知: タスク完了と長時間 Unknown (設計書 §11.2 / §12.7)")
struct PaneNotificationPlannerTimingTests: PaneNotificationPlannerTesting {
  let worktree: WorktreeIdentity
  let other: WorktreeIdentity

  init() throws {
    (worktree, other) = try Self.identities()
  }

  // MARK: - タスク完了

  @Test("最初の完了表示の読み取りは基準とし、既に有効な token を鳴らさない")
  func completionBaselineIsSilent() {
    var planner = baselined([pane("%1", .idle)])

    #expect(
      planner.observeCompletions(
        [PaneID(rawValue: "%1"): .completed(Self.first)], in: worktree, at: Self.clock.now
      ).isEmpty)
    #expect(completions(&planner, ["%1": .completed(Self.first)]).isEmpty)
  }

  @Test("完了表示が新しい (pid, token) で completed になったら1回だけ通知する")
  func completionNotifiesOncePerToken() {
    var planner = completionBaselined(["%1": PaneTaskCompletionDisplay.none])

    #expect(
      completions(&planner, ["%1": .completed(Self.first)])
        == [event("%1", .taskCompleted, completion: Self.first)])
    #expect(completions(&planner, ["%1": .completed(Self.first)]).isEmpty)
    #expect(completions(&planner, ["%1": .dismissed(Self.first)]).isEmpty)
    // 特定できない回などをまたいで同じ token が再び表示されても鳴らさない。
    #expect(completions(&planner, ["%1": PaneTaskCompletionDisplay.none]).isEmpty)
    #expect(completions(&planner, ["%1": .completed(Self.first)]).isEmpty)

    #expect(
      completions(&planner, ["%1": .completed(Self.second)])
        == [event("%1", .taskCompleted, completion: Self.second)])
  }

  @Test("同じ token 文字列でも、別の Agent プロセスが書いたものは新しい完了")
  func completionDistinguishesAgentProcess() {
    var planner = completionBaselined(["%1": .completed(Self.first)])
    let restarted = AgentStampedValue(agentProcessID: 77, text: Self.first.text)

    #expect(
      completions(&planner, ["%1": .completed(restarted)])
        == [event("%1", .taskCompleted, completion: restarted)])
  }

  @Test("dismissed への遷移では通知しない")
  func dismissalIsNotNotified() {
    var planner = completionBaselined(["%1": PaneTaskCompletionDisplay.none])

    #expect(completions(&planner, ["%1": .dismissed(Self.first)]).isEmpty)
  }

  @Test("完了表示が次のターンに入ってから遅れて現れても、通知は1回だけ (#386)")
  func delayedCompletionIsNotifiedOnce() {
    var planner = baselined([pane("%1", .working)])
    _ = completions(&planner, ["%1": PaneTaskCompletionDisplay.none])

    // 応答終了 → 次のターン、の後で初めて token が読めた。
    _ = observe(&planner, [pane("%1", .completed)])
    _ = observe(&planner, [pane("%1", .unknown)])
    _ = observe(&planner, [pane("%1", .working)])
    #expect(
      completions(&planner, ["%1": .completed(Self.first)])
        == [event("%1", .taskCompleted, completion: Self.first)])
    for _ in 0..<3 {
      _ = observe(&planner, [pane("%1", .working)])
      #expect(completions(&planner, ["%1": .completed(Self.first)]).isEmpty)
    }
    _ = observe(&planner, [pane("%1", .completed)])
    _ = observe(&planner, [pane("%1", .working)])
    #expect(completions(&planner, ["%1": .dismissed(Self.first)]).isEmpty)
  }

  @Test("タスク完了を無効にすると通知しないが、token は消費する")
  func disabledCompletion() {
    var planner = completionBaselined(
      ["%1": PaneTaskCompletionDisplay.none],
      settings: PaneNotificationSettings(enabledKinds: [.question]))

    #expect(completions(&planner, ["%1": .completed(Self.first)]).isEmpty)
    planner.settings = PaneNotificationSettings()
    #expect(completions(&planner, ["%1": .completed(Self.first)]).isEmpty)
  }

  @Test("完了表示の基準は状態の基準と独立している")
  func completionBaselineIsIndependentOfStates() {
    let start = Self.clock.now
    var planner = started()

    #expect(
      planner.observeCompletions(
        [PaneID(rawValue: "%1"): .completed(Self.first)], in: worktree, at: start
      ).isEmpty)
    #expect(
      planner.observeCompletions(
        [PaneID(rawValue: "%1"): .completed(Self.second)], in: worktree, at: start)
        == [event("%1", .taskCompleted, completion: Self.second)])
  }

  // MARK: - 長時間の Unknown

  @Test("長時間の Unknown は既定で通知しない")
  func prolongedUnknownIsOffByDefault() {
    let start = Self.clock.now
    var planner = baselined([pane("%1", .unknown)], at: start)

    #expect(planner.nextDeadline == nil)
    #expect(planner.advance(to: start.advanced(by: .seconds(3600))).isEmpty)
  }

  @Test("有効にすると、Unknown が既定10分続いたところで1回だけ通知する")
  func prolongedUnknownNotifiesOnce() throws {
    let start = Self.clock.now
    var planner = baselined(
      [pane("%1", .working)], at: start, settings: Self.withProlongedUnknown)
    let entered = start.advanced(by: .seconds(5))
    _ = planner.observeStates(complete([pane("%1", .unknown)]), in: worktree, at: entered)

    let deadline = try #require(planner.nextDeadline)
    #expect(deadline == entered.advanced(by: .seconds(600)))
    #expect(planner.advance(to: deadline.advanced(by: .seconds(-1))).isEmpty)
    #expect(planner.advance(to: deadline) == [event("%1", .prolongedUnknown)])
    #expect(planner.nextDeadline == nil)
    #expect(
      planner.observeStates(
        complete([pane("%1", .unknown)]), in: worktree, at: deadline.advanced(by: .seconds(60))
      ).isEmpty)
  }

  @Test("Unknown を抜ければ計時をやり直す")
  func prolongedUnknownResetsOnLeaving() throws {
    let start = Self.clock.now
    var planner = baselined(
      [pane("%1", .unknown)], at: start, settings: Self.withProlongedUnknown)
    let left = start.advanced(by: .seconds(300))
    _ = planner.observeStates(complete([pane("%1", .working)]), in: worktree, at: left)
    #expect(planner.nextDeadline == nil)

    let again = start.advanced(by: .seconds(400))
    _ = planner.observeStates(complete([pane("%1", .unknown)]), in: worktree, at: again)

    #expect(try #require(planner.nextDeadline) == again.advanced(by: .seconds(600)))
  }

  @Test("基準の時点で Unknown なら、基準の時刻から数える")
  func prolongedUnknownCountsFromBaseline() throws {
    let start = Self.clock.now
    let planner = baselined(
      [pane("%1", .unknown)], at: start, settings: Self.withProlongedUnknown)

    #expect(try #require(planner.nextDeadline) == start.advanced(by: .seconds(600)))
  }

  @Test("種別不明の注意状態は長時間 Unknown として数えない")
  func attentionUnknownIsNotProlongedUnknown() {
    let start = Self.clock.now
    let planner = baselined(
      [attentionUnknown("%1")], at: start, settings: Self.withProlongedUnknown)

    #expect(planner.nextDeadline == nil)
  }
}
