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

  @Test("状態が変わらず入力の pane 順が変わったら出力も入力順に追従する (設計書 §13)")
  func inputOrderChangesWithoutStateChanges() {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe(
      [pane("%1", .working), pane("%2", .working), pane("%3", .working)], at: start)

    let shown = stabilizer.observe(
      [pane("%2", .working), pane("%1", .working), pane("%3", .working)],
      at: start.advanced(by: .seconds(1)))

    #expect(
      shown == [
        display("%2", .working, changedAt: nil),
        display("%1", .working, changedAt: nil),
        display("%3", .working, changedAt: nil),
      ])
  }

  @Test("入力の pane 順を変えた後に Question になっても出力順は変わらない (設計書 §13)")
  func questionAfterInputReorderKeepsInputOrder() {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe(
      [pane("%1", .working), pane("%2", .working), pane("%3", .working)], at: start)
    let reordered = stabilizer.observe(
      [pane("%2", .working), pane("%1", .working), pane("%3", .working)],
      at: start.advanced(by: .seconds(1)))
    #expect(reordered.map(\.paneID.rawValue) == ["%2", "%1", "%3"])
    let later = start.advanced(by: .seconds(2))

    let shown = stabilizer.observe(
      [pane("%2", .working), pane("%1", .question), pane("%3", .working)], at: later)

    #expect(
      shown == [
        display("%2", .working, changedAt: nil),
        display("%1", .question, changedAt: later),
        display("%3", .working, changedAt: nil),
      ])
  }

  @Test(
    "後ろの pane が Needs Attention になっても出力は入力順を保つ (設計書 §13)",
    arguments: [AgentState.question, .permission, .error])
  func attentionInLaterPaneKeepsInputOrder(_ destination: AgentState) {
    let start = clock.now
    let later = start.advanced(by: .seconds(1))
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe(
      [pane("%1", .working), pane("%2", .working), pane("%3", .working)], at: start)

    let shown = stabilizer.observe(
      [pane("%1", .working), pane("%2", .working), pane("%3", destination)], at: later)

    #expect(
      shown == [
        display("%1", .working, changedAt: nil),
        display("%2", .working, changedAt: nil),
        display("%3", destination, changedAt: later),
      ])
  }

  @Test("入力の pane 順を変えた後に消えた pane は保持中も前回の位置に補う (設計書 §13)")
  func missingPaneRetainsPositionAfterInputReorder() {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe(
      [pane("%1", .working), pane("%2", .working), pane("%3", .working)], at: start)
    let reordered = stabilizer.observe(
      [pane("%2", .working), pane("%1", .working), pane("%3", .working)],
      at: start.advanced(by: .seconds(1)))
    #expect(reordered.map(\.paneID.rawValue) == ["%2", "%1", "%3"])
    let remaining = [pane("%2", .working), pane("%3", .working)]
    let expected = [
      display("%2", .working, changedAt: nil),
      display("%1", .working, changedAt: nil),
      display("%3", .working, changedAt: nil),
    ]

    let missing = stabilizer.observe(remaining, at: start.advanced(by: .seconds(2)))

    #expect(missing == expected)
    #expect(stabilizer.nextDeadline == start.advanced(by: .seconds(11)))
    #expect(stabilizer.observe(remaining, at: start.advanced(by: .seconds(10))) == expected)
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
      stabilizer.observe([pane("%1", .unknown, unknownReason: .signalMissing)], at: start)
        == [display("%1", .unknown, changedAt: nil)])
    _ = stabilizer.observe(
      [pane("%1", .unknown, unknownReason: .signalMissing)], at: start.advanced(by: .seconds(1)))

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
    let initial = stabilizer.observe(
      [pane("%1", .unknown, unknownReason: .signalMissing)], at: start)
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
    _ = stabilizer.observe([pane("%1", .unknown, unknownReason: .signalMissing)], at: start)
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

  @Test(
    "基準観測から Unknown + needsAttention なら理由を問わず確定済みで、次の変化に時刻が入る",
    arguments: [UnknownReason.signalMissing, .adapterUndetermined])
  func baselineAttentionUnknownIsAlreadyResolved(_ reason: UnknownReason) throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    #expect(
      stabilizer.observe([attentionUnknown("%1", reason: reason)], at: start).first?.changedAt
        == nil)
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
      stabilizer.observe([pane("%1", .unknown, unknownReason: .signalMissing)], at: appearedAt)
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

  @Test(
    "signalMissing 以外の基準 Unknown は初回の確定でも最終更新を持つ",
    arguments: [
      UnknownReason.adapterUndetermined, .screenUnavailable, .observationFailed,
      .livenessUnavailable, .screenAttributesUnavailable,
    ], [AgentState.working, .idle, .question, .permission, .error, .completed])
  func nonProvisionalUnknownResolutionHasTimestamp(
    reason: UnknownReason, destination: AgentState
  ) throws {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .unknown, unknownReason: reason)], at: start)
    let latest = [pane("%1", destination)]
    let observedAt = start.advanced(by: .seconds(3600))
    let first = stabilizer.observe(latest, at: observedAt)
    if destination == .idle {
      #expect(first == [display("%1", .unknown, changedAt: nil)])
      let deadline = try #require(stabilizer.nextDeadline)
      #expect(deadline == observedAt.advanced(by: .seconds(9)))
      #expect(
        stabilizer.observe(latest, at: deadline)
          == [display("%1", destination, changedAt: deadline)])
    } else {
      #expect(first == [display("%1", destination, changedAt: observedAt)])
    }
  }

  @Test("理由の無い基準 Unknown も仮の Unknown に含めない")
  func unknownWithoutReasonResolutionHasTimestamp() {
    let start = clock.now
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .unknown, unknownReason: nil)], at: start)
    let later = start.advanced(by: .seconds(3600))
    #expect(
      stabilizer.observe([pane("%1", .working)], at: later)
        == [display("%1", .working, changedAt: later)])
  }

  private func pane(
    _ id: String, _ state: AgentState, unknownReason: UnknownReason? = .adapterUndetermined
  ) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      observation: AgentStateObservation(
        state: state, adapterID: AgentAdapterID(rawValue: "test"), observedAt: .distantPast,
        unknownReason: state == .unknown ? unknownReason : nil))
  }

  private func attentionUnknown(
    _ id: String, reason: UnknownReason = .adapterUndetermined
  ) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      observation: AgentStateObservation(
        state: .unknown, adapterID: AgentAdapterID(rawValue: "codex"), observedAt: Date(),
        category: .needsAttention, unknownReason: reason))
  }

  private func display(
    _ id: String, _ state: AgentState, changedAt: ContinuousClock.Instant?
  ) -> PaneDisplayState {
    PaneDisplayState(
      paneID: PaneID(rawValue: id), state: state, category: state.worktreeCategory,
      changedAt: changedAt)
  }
}
