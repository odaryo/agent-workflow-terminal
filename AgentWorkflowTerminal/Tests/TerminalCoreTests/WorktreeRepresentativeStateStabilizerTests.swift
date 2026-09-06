import Foundation
import TerminalCore
import Testing

@Suite("worktree代表状態の安定化 (設計書 §12.2)")
// 型名を対象ファイル名へ合わせると、既定の上限を超える。
// swiftlint:disable:next type_name
struct WorktreeRepresentativeStateStabilizerTests {
  private let clock = ContinuousClock()

  @Test("規則1: Needs Attention と Ready for Review は即時反映する")
  func urgentStatesAreImmediate() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    #expect(stabilizer.observe(state: state(.working), at: now) == state(.working))
    #expect(
      stabilizer.observe(state: state(.permission), at: now.advanced(by: .seconds(1)))
        == state(.permission)
    )
    #expect(
      stabilizer.observe(state: state(.completed), at: now.advanced(by: .seconds(2)))
        == state(.completed)
    )
  }

  @Test("規則2・8: Working から Idle は既定の9秒未満で保持し境界ちょうどで反映する")
  func idleIsHeldThroughBoundary() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    #expect(stabilizer.observe(state: state(.working), at: now) == state(.working))
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(1)))
        == state(.working)
    )
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(5)))
        == state(.working)
    )
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(10)))
        == state(.idle)
    )
  }

  @Test("規則2: 遷移元を問わず Idle と Unknown への分類変更を保持する")
  func lowerCategoriesAreAlwaysHeld() {
    let transitions: [(AgentState, AgentState)] = [
      (.idle, .unknown),
      (.unknown, .idle),
      (.completed, .idle),
    ]

    for (source, destination) in transitions {
      let now = clock.now
      var stabilizer = WorktreeRepresentativeStateStabilizer(holdDuration: .seconds(3))
      #expect(stabilizer.observe(state: state(source), at: now) == state(source))
      #expect(
        stabilizer.observe(state: state(destination), at: now.advanced(by: .seconds(1)))
          == state(source)
      )
      #expect(
        stabilizer.observe(state: state(destination), at: now.advanced(by: .seconds(4)))
          == state(destination)
      )
    }
  }

  @Test("規則3: 保持中に表示中の分類へ戻ると表示は一度も変わらない")
  func returningToDisplayedCategoryCancelsHold() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    #expect(stabilizer.observe(state: state(.working), at: now) == state(.working))
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(1)))
        == state(.working)
    )
    #expect(
      stabilizer.observe(state: state(.working), at: now.advanced(by: .seconds(2)))
        == state(.working)
    )
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(11)))
        == state(.working)
    )
  }

  @Test("規則4: Idle の保持中に Permission が来ると即時反映する")
  func urgentStateCancelsHold() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    #expect(stabilizer.observe(state: state(.working), at: now) == state(.working))
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(1)))
        == state(.working)
    )
    #expect(
      stabilizer.observe(state: state(.permission), at: now.advanced(by: .seconds(2)))
        == state(.permission)
    )
  }

  @Test("規則5: 保持中の Idle から Unknown は起点をリセットせず最後の値を反映する")
  func pendingValueChangesWithoutResettingStart() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    #expect(stabilizer.observe(state: state(.working), at: now) == state(.working))
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(1)))
        == state(.working)
    )
    #expect(
      stabilizer.observe(state: state(.unknown), at: now.advanced(by: .seconds(9)))
        == state(.working)
    )
    #expect(
      stabilizer.observe(state: state(.unknown), at: now.advanced(by: .seconds(11)))
        == state(.unknown)
    )
  }

  @Test("規則6: 同じ分類の状態と paneID の変化は即時反映する")
  func sameCategoryChangesAreImmediate() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    #expect(stabilizer.observe(state: state(.question, paneID: "%0"), at: now)?.state == .question)
    let permission = state(.permission, paneID: "%1")
    #expect(
      stabilizer.observe(state: permission, at: now.advanced(by: .seconds(1))) == permission
    )
  }

  @Test("規則6: 分類と状態が同じなら paneID だけの変化を即時反映する")
  func paneIDOnlyChangeIsImmediate() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()
    let nextPane = state(.working, paneID: "%1")

    #expect(
      stabilizer.observe(state: state(.working, paneID: "%0"), at: now)?.paneID.rawValue
        == "%0"
    )
    #expect(
      stabilizer.observe(state: nextPane, at: now.advanced(by: .seconds(1))) == nextPane
    )
  }

  @Test("満了予定時刻は起点を保ち、保持破棄と満了で nil に戻る")
  func pendingTransitionDeadlineLifecycle() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    _ = stabilizer.observe(state: state(.working), at: now)
    #expect(stabilizer.pendingTransitionDeadline == nil)

    _ = stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(1)))
    #expect(stabilizer.pendingTransitionDeadline == now.advanced(by: .seconds(10)))

    _ = stabilizer.observe(state: state(.unknown), at: now.advanced(by: .seconds(5)))
    #expect(stabilizer.pendingTransitionDeadline == now.advanced(by: .seconds(10)))

    _ = stabilizer.observe(state: state(.working), at: now.advanced(by: .seconds(6)))
    #expect(stabilizer.pendingTransitionDeadline == nil)

    _ = stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(7)))
    #expect(stabilizer.pendingTransitionDeadline == now.advanced(by: .seconds(16)))

    _ = stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(16)))
    #expect(stabilizer.pendingTransitionDeadline == nil)
  }

  @Test("規則7: 初回観測は Idle・Unknown・nil を含め即時反映する")
  func firstObservationIsImmediate() {
    let now = clock.now

    for initial in [state(.idle), state(.unknown)] {
      var stabilizer = WorktreeRepresentativeStateStabilizer()
      #expect(stabilizer.observe(state: initial, at: now) == initial)
    }

    var stabilizer = WorktreeRepresentativeStateStabilizer()
    #expect(stabilizer.observe(state: nil, at: now) == nil)
    #expect(
      stabilizer.observe(state: state(.working), at: now.advanced(by: .seconds(1)))
        == state(.working)
    )
  }

  @Test("nil へ入る遷移を保持し Idle と nil は同じ分類として扱う")
  func noPanesUsesIdleClassification() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()

    #expect(stabilizer.observe(state: state(.working), at: now) == state(.working))
    #expect(stabilizer.observe(state: nil, at: now.advanced(by: .seconds(1))) == state(.working))
    #expect(stabilizer.observe(state: nil, at: now.advanced(by: .seconds(11))) == nil)
    #expect(
      stabilizer.observe(state: state(.idle), at: now.advanced(by: .seconds(12)))
        == state(.idle)
    )
    #expect(stabilizer.observe(state: nil, at: now.advanced(by: .seconds(13))) == nil)
  }

  @Test("unknown の Needs Attention override は Unknown として保持せず即時反映する")
  func unknownNeedsAttentionOverrideIsImmediate() {
    let now = clock.now
    var stabilizer = WorktreeRepresentativeStateStabilizer()
    let pane = PaneAgentState(
      id: PaneID(rawValue: "%1"),
      observation: AgentStateObservation(
        state: .unknown,
        adapterID: AgentAdapterID(rawValue: "test"),
        observedAt: Date(timeIntervalSince1970: 0),
        category: .needsAttention
      )
    )
    let overridden = resolveWorktreeRepresentativeState(panes: [pane])

    #expect(stabilizer.observe(state: state(.working), at: now) == state(.working))
    #expect(pane.unknownCategoryOverride == .needsAttention)
    #expect(
      stabilizer.observe(state: overridden, at: now.advanced(by: .seconds(1))) == overridden
    )
  }

  private func state(
    _ agentState: AgentState,
    paneID: String = "%0"
  ) -> WorktreeRepresentativeState {
    WorktreeRepresentativeState(
      category: agentState.worktreeCategory,
      state: agentState,
      paneID: PaneID(rawValue: paneID)
    )
  }
}
