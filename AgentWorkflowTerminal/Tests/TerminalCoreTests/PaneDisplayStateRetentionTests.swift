import Foundation
import TerminalCore
import Testing

@Suite("pane の初出と観測消失の保持 (設計書 §13 / Issue #387)")
struct PaneDisplayStateRetentionTests {
  private let start = ContinuousClock().now

  @Test("最初の観測に在る pane は同じ nil の最終更新で、状態が変わるとその時刻になる")
  func firstObservationsShareUnchangedTimestamp() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    let first = stabilizer.observe([pane("%1", .working), pane("%2", .working)], at: at(0))
    let both = stabilizer.observe([pane("%1", .working), pane("%2", .working)], at: at(3))

    #expect(first.map(\.changedAt) == [nil, nil])
    #expect(both.map(\.changedAt) == [nil, nil])
    #expect(both.map(\.paneID.rawValue) == ["%1", "%2"])
    let changed = stabilizer.observe([pane("%1", .question), pane("%2", .working)], at: at(4))
    #expect(changed.first?.changedAt == at(4))
    #expect(changed.last?.changedAt == nil)
  }

  @Test("2回目以降に初めて現れた pane はその観測時刻を最終更新とし、以後の同じ状態では保つ")
  func laterPanesUseTheirFirstObservationTime() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: at(0))

    let second = stabilizer.observe([pane("%1", .working), pane("%2", .working)], at: at(3))
    #expect(second.map(\.changedAt) == [nil, at(3)])
    let third = stabilizer.observe(
      [pane("%3", .working), pane("%1", .working), pane("%2", .working)], at: at(3600))
    #expect(third.map(\.changedAt) == [at(3600), nil, at(3)])
  }

  @Test("最初の空の観測も数え、その後に初めて現れた pane はすべて観測時刻を最終更新に持つ")
  func emptyFirstObservationStillEstablishesBaseline() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    #expect(stabilizer.observe([], at: at(0)).isEmpty)

    let second = stabilizer.observe([pane("%1", .working), pane("%2", .idle)], at: at(3))
    #expect(second.map(\.changedAt) == [at(3), at(3)])
    let third = stabilizer.observe(
      [pane("%1", .working), pane("%2", .idle), pane("%3", .question)], at: at(4))
    #expect(third.map(\.changedAt) == [at(3), at(3), at(4)])
  }

  @Test("消えた pane は消失時点の表示のまま9秒保持し、繰り返し観測しても外す期限を延ばさない")
  func missingPaneKeepsLastDisplayUntilRemovalDeadline() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: at(0))
    let previous = stabilizer.observe([pane("%1", .permission)], at: at(1))

    #expect(stabilizer.observe([], at: at(2)) == previous)
    #expect(stabilizer.nextDeadline == at(11))
    #expect(stabilizer.observe([], at: at(10)) == previous)
    #expect(stabilizer.nextDeadline == at(11))
    #expect(stabilizer.observe([], at: at(11)).isEmpty)
    #expect(stabilizer.nextDeadline == nil)
  }

  @Test("消失中に状態保持の期限で最後の入力を渡し直すと期限が前進し、消失期限で表示も期限もなくなる")
  func replayingLastInputAtDeadlinesAdvancesUntilRemoval() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: at(0))
    let previous = stabilizer.observe([pane("%1", .idle)], at: at(1))

    let latest: [PaneAgentState] = []
    #expect(stabilizer.observe(latest, at: at(5)) == previous)
    let transitionDeadline = try #require(stabilizer.nextDeadline)
    #expect(transitionDeadline == at(10))

    #expect(stabilizer.observe(latest, at: transitionDeadline) == previous)
    let removalDeadline = try #require(stabilizer.nextDeadline)
    #expect(removalDeadline == at(14))
    try #require(removalDeadline > transitionDeadline)

    #expect(stabilizer.observe(latest, at: removalDeadline).isEmpty)
    #expect(stabilizer.nextDeadline == nil)
  }

  @Test("先頭の pane が消えても保持中は前回の位置と表示に残り、戻っても順序が変わらない")
  func missingLeadingPaneKeepsItsPositionAndDisplay() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    let original = [pane("%1", .working), pane("%2", .working), pane("%3", .working)]
    let previous = stabilizer.observe(original, at: at(0))

    #expect(
      stabilizer.observe([pane("%2", .working), pane("%3", .working)], at: at(1)) == previous)
    #expect(stabilizer.observe(original, at: at(2)) == previous)
  }

  @Test("新規 pane が増えて入力順が変わると入力順に追従し、消失中の pane の表示を保つ")
  func panesFollowChangedInputOrderWhileMissingDisplaysStayUnchanged() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    let previous = stabilizer.observe(
      [pane("%1", .working), pane("%2", .working), pane("%3", .working), pane("%4", .working)],
      at: at(0))

    let missing = stabilizer.observe([pane("%1", .working), pane("%4", .working)], at: at(1))
    #expect(missing == previous)
    let next = stabilizer.observe(
      [pane("%5", .working), pane("%4", .working), pane("%1", .working), pane("%6", .working)],
      at: at(2))
    #expect(next.map(\.paneID.rawValue) == ["%5", "%2", "%3", "%4", "%1", "%6"])
    #expect(next.first { $0.paneID.rawValue == "%5" }?.changedAt == at(2))
    #expect(next.first { $0.paneID.rawValue == "%6" }?.changedAt == at(2))
    #expect(
      next.filter { $0.paneID.rawValue == "%2" || $0.paneID.rawValue == "%3" }
        == Array(previous[1...2]))
    #expect(stabilizer.observe([], at: at(3)) == next)
  }

  // 消失中の pane と新規 pane の前後は観測から決められないため、既存 pane の相対順だけを固定する。
  @Test("新規 pane が先頭に増えても、保持中の pane を含む既存 pane は前回の相対順を保つ")
  func existingPanesKeepRelativeOrderWhenNewPaneAppears() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe(
      [pane("%1", .working), pane("%2", .working), pane("%3", .working)], at: at(0))

    let shown = stabilizer.observe([pane("%4", .working), pane("%3", .working)], at: at(1))

    #expect(shown.filter { $0.changedAt == nil }.map(\.paneID.rawValue) == ["%1", "%2", "%3"])
    #expect(shown.first { $0.paneID.rawValue == "%4" }?.changedAt == at(1))
  }

  @Test("消失と新規出現が重なる間も観測した pane は入力順に並び、全 pane が揃うと全体が tmux 順に戻る")
  func allPanesReturnToTmuxOrderAfterOverlappingAbsenceAndArrival() {
    var stabilizer = PaneDisplayStateStabilizer()
    let originalIDs = ["%1", "%2", "%3", "%4", "%5"]
    _ = stabilizer.observe(originalIDs.map { pane($0, .working) }, at: at(0))

    let partialIDs = ["%1", "%2", "%3", "%4", "%6"]
    let partial = stabilizer.observe(partialIDs.map { pane($0, .working) }, at: at(1))
    let observedIDs = Set(partialIDs)
    let partialPaneIDs = partial.map(\.paneID.rawValue)
    #expect(partialPaneIDs.filter { observedIDs.contains($0) } == partialIDs)

    let allIDs = ["%1", "%2", "%3", "%4", "%5", "%6"]
    let restored = stabilizer.observe(allIDs.map { pane($0, .working) }, at: at(2))
    #expect(restored.map(\.paneID.rawValue) == allIDs)
  }

  @Test("nextDeadline は状態の保持期限と消失の期限の早い方を返す", arguments: [false, true])
  func deadlineIncludesMissingPanes(removalFirst: Bool) throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working), pane("%2", .working)], at: at(0))
    if removalFirst {
      _ = stabilizer.observe([pane("%2", .working)], at: at(1))
    } else {
      _ = stabilizer.observe([pane("%1", .working), pane("%2", .idle)], at: at(1))
    }
    _ = stabilizer.observe([pane("%2", .idle)], at: at(3))

    #expect(stabilizer.nextDeadline == at(10))
    _ = stabilizer.observe([pane("%2", .idle)], at: at(10))
    #expect(stabilizer.nextDeadline == at(12))
    _ = stabilizer.observe([pane("%2", .idle)], at: at(12))
    #expect(stabilizer.nextDeadline == nil)
  }

  @Test("再出現した pane は元の最終更新を保ち、次の消失から改めて9秒保持する")
  func reappearanceResetsOnlyRemovalDeadline() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: at(0))
    let previous = stabilizer.observe([pane("%1", .question)], at: at(1))
    _ = stabilizer.observe([], at: at(2))

    #expect(stabilizer.observe([pane("%1", .question)], at: at(10)) == previous)
    #expect(stabilizer.nextDeadline == nil)
    #expect(stabilizer.observe([], at: at(11)) == previous)
    #expect(stabilizer.nextDeadline == at(20))
    #expect(stabilizer.observe([], at: at(19)) == previous)
    #expect(stabilizer.observe([], at: at(20)).isEmpty)
  }

  @Test("消失期限後の再出現は期限の再観測の有無によらず初出になり、その観測時刻を最終更新に持つ", arguments: [false, true])
  func reappearanceAfterExpiryIsNew(observeDeadline: Bool) throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: at(0))
    _ = stabilizer.observe([pane("%1", .question)], at: at(1))
    _ = stabilizer.observe([pane("%1", .idle)], at: at(2))
    _ = stabilizer.observe([], at: at(3))
    if observeDeadline { _ = stabilizer.observe([], at: at(12)) }

    let shown = stabilizer.observe([pane("%1", .idle)], at: at(13))
    let only = try #require(shown.first)
    #expect(only.state == .idle)
    #expect(only.changedAt == at(13))
    #expect(stabilizer.nextDeadline == nil)
  }

  @Test("消失の保持も指定された holdDuration を使う")
  func missingPaneUsesConfiguredHoldDuration() throws {
    var stabilizer = PaneDisplayStateStabilizer(holdDuration: .seconds(2))
    let previous = stabilizer.observe([pane("%1", .working)], at: at(0))

    #expect(stabilizer.observe([], at: at(1)) == previous)
    #expect(stabilizer.nextDeadline == at(3))
    #expect(stabilizer.observe([], at: at(2)) == previous)
    #expect(stabilizer.observe([], at: at(3)).isEmpty)
  }

  private func at(_ seconds: Int) -> ContinuousClock.Instant {
    start.advanced(by: .seconds(seconds))
  }

  private func pane(_ id: String, _ state: AgentState) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id), state: state, lastUpdatedAt: Date(timeIntervalSince1970: 0))
  }
}
