import Foundation
import TerminalCore
import Testing

@Suite("pane の初出と観測消失の保持 (設計書 §13 / Issue #387)")
struct PaneDisplayStateRetentionTests {
  private let start = ContinuousClock().now

  @Test("別々の時刻に初めて見た pane は同じ最終更新で、状態が変わるとその時刻になる")
  func firstObservationsShareUnchangedTimestamp() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    let first = stabilizer.observe([pane("%2", .working)], at: at(0))
    let both = stabilizer.observe([pane("%1", .working), pane("%2", .working)], at: at(3))

    #expect(first.first?.changedAt == nil)
    #expect(both.map(\.changedAt) == [nil, nil])
    #expect(both.map(\.paneID.rawValue) == ["%1", "%2"])
    let changed = stabilizer.observe([pane("%1", .question), pane("%2", .working)], at: at(4))
    #expect(changed.first?.changedAt == at(4))
    #expect(changed.last?.changedAt == nil)
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

  @Test("消失中は状態保持の期限を過ぎても最後に出した表示を変えない")
  func disappearanceFreezesDisplayEvenWhenTransitionIsDue() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe([pane("%1", .working)], at: at(0))
    let previous = stabilizer.observe([pane("%1", .idle)], at: at(1))

    #expect(stabilizer.observe([], at: at(5)) == previous)
    #expect(stabilizer.observe([], at: at(10)) == previous)
    #expect(stabilizer.observe([], at: at(13)) == previous)
    #expect(stabilizer.observe([], at: at(14)).isEmpty)
  }

  @Test("入力の pane を入力順に置き、保持中の pane は消える前の相対順で後ろに置く")
  func missingPanesKeepDeterministicRelativeOrder() throws {
    var stabilizer = PaneDisplayStateStabilizer()
    _ = stabilizer.observe(
      [pane("%3", .working), pane("%1", .working), pane("%2", .working)], at: at(0))

    let first = stabilizer.observe([pane("%2", .working)], at: at(1))
    #expect(first.map(\.paneID.rawValue) == ["%2", "%3", "%1"])
    let next = stabilizer.observe([pane("%4", .idle), pane("%2", .working)], at: at(2))
    #expect(next.map(\.paneID.rawValue) == ["%4", "%2", "%3", "%1"])
    #expect(stabilizer.observe([], at: at(3)).map(\.paneID.rawValue) == ["%4", "%2", "%3", "%1"])
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

  @Test("消失期限後の再出現は期限の再観測の有無によらず初出になる", arguments: [false, true])
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
    #expect(only.changedAt == nil)
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
