import Foundation
import TerminalCore
import Testing

@Suite("Overview の pane 状態の安定化 (設計書 §12.2 / §13)")
struct PaneDisplayStateStabilizerTests {
  private let clock = ContinuousClock()

  @Test("初めて見た pane は即時に表示し、最終更新はまだ変わっていない値になる")
  func firstObservationIsImmediate() throws {
    let now = clock.now
    var stabilizer = PaneDisplayStateStabilizer()

    let shown = stabilizer.observe([pane("%1", .working)], at: now)

    #expect(shown == [display("%1", .working, changedAt: nil)])
    #expect(stabilizer.nextDeadline == nil)
  }

  @Test("Working から Unknown へは9秒保持し、その間は最終更新も動かない")
  func lowerCategoryIsHeldWithoutBumpingChangedAt() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: start)

    let held = stabilizer.observe(
      [pane("%1", .unknown)], at: start.advanced(by: .seconds(1)))

    #expect(held == [display("%1", .working, changedAt: nil)])
    #expect(stabilizer.nextDeadline == start.advanced(by: .seconds(10)))
  }

  @Test("保持の期限に同じ入力を渡し直すと反映し、最終更新は期限の時刻になる")
  func heldTransitionAppliesAtDeadline() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: start)
    let latest = [pane("%1", .idle)]
    _ = stabilizer.observe(latest, at: start.advanced(by: .seconds(1)))
    let deadline = try #require(stabilizer.nextDeadline)

    let shown = stabilizer.observe(latest, at: deadline)

    #expect(shown == [display("%1", .idle, changedAt: deadline)])
    #expect(stabilizer.nextDeadline == nil)
  }

  @Test(
    "Needs Attention と応答終了への遷移は即時に反映し、最終更新を進める",
    arguments: [AgentState.question, .permission, .error, .completed])
  func urgentTransitionsAreImmediate(_ destination: AgentState) throws {
    let start = clock.now
    let later = start.advanced(by: .seconds(1))
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: start)

    let shown = stabilizer.observe([pane("%1", destination)], at: later)

    #expect(shown == [display("%1", destination, changedAt: later)])
  }

  @Test("種別不明の注意状態 (Unknown + needsAttention) は大分類を保ったまま即時に反映する")
  func unknownNeedingAttentionIsImmediate() throws {
    let start = clock.now
    let later = start.advanced(by: .seconds(1))
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: start)

    let shown = stabilizer.observe([attentionUnknown("%1")], at: later)

    let only = try #require(shown.first)
    #expect(only.state == .unknown)
    #expect(only.category == .needsAttention)
    #expect(only.changedAt == later)
  }

  @Test("同じ分類の中の状態の変化 (Question → Permission) は即時に反映する")
  func sameCategoryChangeIsImmediate() throws {
    let start = clock.now
    let later = start.advanced(by: .seconds(2))
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .question)], at: start)

    let shown = stabilizer.observe([pane("%1", .permission)], at: later)

    #expect(shown == [display("%1", .permission, changedAt: later)])
  }

  @Test("状態が変わらない観測では最終更新を進めない")
  func unchangedStateKeepsChangedAt() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: start)

    let shown = stabilizer.observe([pane("%1", .working)], at: start.advanced(by: .seconds(5)))

    #expect(shown == [display("%1", .working, changedAt: nil)])
  }

  @Test("pane ごとに独立して保持し、出力は入力の順を保つ")
  func panesAreIndependentAndOrdered() throws {
    let start = clock.now
    let later = start.advanced(by: .seconds(1))
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working), pane("%2", .working)], at: start)

    let shown = stabilizer.observe([pane("%2", .question), pane("%1", .idle)], at: later)

    #expect(
      shown == [
        display("%2", .question, changedAt: later),
        display("%1", .working, changedAt: nil),
      ])
  }

  @Test("保持の期限は保持中の pane のうち最も早いもの")
  func nextDeadlineIsTheEarliestPendingHold() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working), pane("%2", .working)], at: start)
    _ = stabilizer.observe(
      [pane("%1", .working), pane("%2", .idle)], at: start.advanced(by: .seconds(3)))
    _ = stabilizer.observe(
      [pane("%1", .idle), pane("%2", .idle)], at: start.advanced(by: .seconds(5)))

    #expect(stabilizer.nextDeadline == start.advanced(by: .seconds(12)))
  }

  @Test("入力から消えた pane は9秒保持し、その間の再出現は元の状態と保持期限を引き継ぐ")
  func removedPaneRetainsPendingTransition() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: start)
    _ = stabilizer.observe([pane("%1", .question)], at: start.advanced(by: .seconds(1)))
    _ = stabilizer.observe([pane("%1", .idle)], at: start.advanced(by: .seconds(2)))
    let previous = display("%1", .question, changedAt: start.advanced(by: .seconds(1)))

    let removed = stabilizer.observe([], at: start.advanced(by: .seconds(3)))
    #expect(removed == [previous])
    #expect(stabilizer.nextDeadline == start.advanced(by: .seconds(11)))

    let shown = stabilizer.observe([pane("%1", .idle)], at: start.advanced(by: .seconds(4)))
    #expect(shown == [previous])
    #expect(stabilizer.nextDeadline == start.advanced(by: .seconds(11)))

    let deadline = start.advanced(by: .seconds(11))
    #expect(
      stabilizer.observe([pane("%1", .idle)], at: deadline)
        == [display("%1", .idle, changedAt: deadline)])
  }

  @Test("保持時間は差し替えられる")
  func holdDurationIsConfigurable() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer(holdDuration: .seconds(2))
    _ = stabilizer.observe([pane("%1", .working)], at: start)
    _ = stabilizer.observe([pane("%1", .unknown)], at: start.advanced(by: .seconds(1)))

    #expect(stabilizer.nextDeadline == start.advanced(by: .seconds(3)))
  }

  @Test("基準観測の仮の Unknown が初めて Working になるときだけ最終更新を進めない")
  func baselineUnknownBecomesWorkingWithoutTimestamp() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    #expect(
      stabilizer.observe([pane("%1", .unknown)], at: start)
        == [display("%1", .unknown, changedAt: nil)])
    _ = stabilizer.observe([pane("%1", .unknown)], at: start.advanced(by: .seconds(1)))

    let resolved = stabilizer.observe(
      [pane("%1", .working)], at: start.advanced(by: .seconds(2)))
    #expect(resolved == [display("%1", .working, changedAt: nil)])
    #expect(stabilizer.nextDeadline == nil)

    let later = start.advanced(by: .seconds(3))
    #expect(
      stabilizer.observe([pane("%1", .question)], at: later)
        == [display("%1", .question, changedAt: later)])
  }

  @Test("基準観測の仮の Unknown が初めて Idle になるまで9秒保持し、満了しても最終更新は nil")
  func baselineUnknownBecomesIdleAfterHoldWithoutTimestamp() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    let initial = stabilizer.observe([pane("%1", .unknown)], at: start)
    let latest = [pane("%1", .idle)]
    #expect(stabilizer.observe(latest, at: start.advanced(by: .seconds(1))) == initial)
    let deadline = try #require(stabilizer.nextDeadline)
    #expect(deadline == start.advanced(by: .seconds(10)))
    #expect(stabilizer.observe(latest, at: start.advanced(by: .seconds(9))) == initial)
    #expect(
      stabilizer.observe(latest, at: deadline)
        == [display("%1", .idle, changedAt: nil)])
    #expect(stabilizer.nextDeadline == nil)

    let later = deadline.advanced(by: .seconds(1))
    #expect(
      stabilizer.observe([pane("%1", .working)], at: later)
        == [display("%1", .working, changedAt: later)])
  }

  @Test("基準観測の仮の Unknown は needsAttention で初めて確定し、次の確定では時刻を進める")
  func attentionUnknownResolvesBaselineOnlyOnce() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .unknown)], at: start)
    let resolved = try #require(
      stabilizer.observe(
        [attentionUnknown("%1")], at: start.advanced(by: .seconds(1))
      ).first)
    #expect(resolved.state == .unknown)
    #expect(resolved.category == .needsAttention)
    #expect(resolved.changedAt == nil)

    let later = start.advanced(by: .seconds(2))
    #expect(
      stabilizer.observe([pane("%1", .question)], at: later)
        == [display("%1", .question, changedAt: later)])
  }

  @Test("基準観測から Unknown + needsAttention なら確定済みで、次の変化に時刻が入る")
  func baselineAttentionUnknownIsAlreadyResolved() throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    #expect(stabilizer.observe([attentionUnknown("%1")], at: start).first?.changedAt == nil)
    let later = start.advanced(by: .seconds(1))
    #expect(
      stabilizer.observe([pane("%1", .working)], at: later)
        == [display("%1", .working, changedAt: later)])
  }

  @Test(
    "後から Unknown で現れた pane は初出時刻を持ち、初めて状態が決まる時も更新する",
    arguments: [AgentState.idle, .working])
  func laterUnknownPaneUpdatesTimestampWhenResolved(_ destination: AgentState) throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([], at: start)
    let appearedAt = start.advanced(by: .seconds(1))
    #expect(
      stabilizer.observe([pane("%1", .unknown)], at: appearedAt)
        == [display("%1", .unknown, changedAt: appearedAt)])
    let latest = [pane("%1", destination)]
    let observedAt = start.advanced(by: .seconds(2))
    let first = stabilizer.observe(latest, at: observedAt)
    if destination == .idle {
      #expect(first == [display("%1", .unknown, changedAt: appearedAt)])
      let deadline = try #require(stabilizer.nextDeadline)
      #expect(deadline == start.advanced(by: .seconds(11)))
      #expect(
        stabilizer.observe(latest, at: deadline)
          == [display("%1", destination, changedAt: deadline)])
    } else {
      #expect(first == [display("%1", destination, changedAt: observedAt)])
    }
  }

  private func pane(_ id: String, _ state: AgentState) -> PaneAgentState {
    PaneAgentState(id: PaneID(rawValue: id), state: state, lastUpdatedAt: Date())
  }

  private func attentionUnknown(_ id: String) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      observation: AgentStateObservation(
        state: .unknown, adapterID: AgentAdapterID(rawValue: "codex"), observedAt: Date(),
        category: .needsAttention, unknownReason: .adapterUndetermined))
  }

  private func display(
    _ id: String, _ state: AgentState, changedAt: ContinuousClock.Instant?
  ) -> PaneDisplayState {
    PaneDisplayState(
      paneID: PaneID(rawValue: id), state: state, category: state.worktreeCategory,
      changedAt: changedAt)
  }
}
