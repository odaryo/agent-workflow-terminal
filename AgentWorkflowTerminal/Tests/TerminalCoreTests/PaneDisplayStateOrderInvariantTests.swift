import Foundation
import TerminalCore
import Testing

@Suite("同順位の pane の相対順の不変条件 (設計書 §13 / Issue #387)")
struct PaneDisplayStateOrderInvariantTests {
  private let start = ContinuousClock().now

  @Test("R5: 前への新規 pane と別々の pane の消失・復帰が重なっても同順位の相対順を保つ")
  func reappearingPaneDoesNotCrossRetainedPeer() {
    var stabilizer = PaneDisplayStateStabilizer()
    let inputs = [
      ["%2", "%3", "%4"], ["%1", "%3", "%4"],
      ["%1", "%2", "%4"], ["%1", "%2", "%3", "%4"],
    ]
    var previous: [PaneDisplayState] = []

    for (step, ids) in inputs.enumerated() {
      let current = stabilizer.observe(
        ids.map { pane($0, .working) }, at: start.advanced(by: .seconds(step)))
      expectStableTies(previous, current, seed: 0, step: step)
      #expect(current.filter { $0.changedAt == nil }.map(\.paneID.rawValue) == ["%2", "%3", "%4"])
      #expect(current.filter { $0.changedAt == nil }.allSatisfy { $0.category == .working })
      if step > 0 {
        #expect(
          current.first { $0.paneID.rawValue == "%1" }?.changedAt
            == start.advanced(by: .seconds(1)))
      }
      previous = current
    }
  }

  @Test(
    "固定 tmux 順のランダムな部分集合・状態・期限再観測でも同順位の相対順を保つ",
    arguments: Array(1...256))
  func randomizedObservationsPreserveUnchangedTies(seed: Int) {
    var random = OrderRandomGenerator(state: UInt64(seed))
    var stabilizer = PaneDisplayStateStabilizer()
    let ids = (1...6).map { "%\($0)" }
    let choices: [AgentState] = [
      .working, .idle, .unknown, .question, .permission, .completed, .error,
    ]
    var states = Array(repeating: AgentState.unknown, count: ids.count)
    var instant = start
    var previous = stabilizer.observe(ids.map { pane($0, .unknown) }, at: instant)
    var latest = ids.map { pane($0, .unknown) }

    for step in 1...40 {
      let next = instant.advanced(by: .seconds([1, 2, 9, 10][random.index(4)]))
      while let deadline = stabilizer.nextDeadline, deadline <= next {
        let replayed = stabilizer.observe(latest, at: deadline)
        expectStableTies(previous, replayed, seed: seed, step: step)
        previous = replayed
      }
      instant = next
      latest = ids.enumerated().compactMap { index, id in
        if random.index(4) == 0 { states[index] = choices[random.index(choices.count)] }
        return random.index(3) == 0 ? nil : pane(id, states[index])
      }
      let current = stabilizer.observe(latest, at: instant)
      expectStableTies(previous, current, seed: seed, step: step)
      previous = current
    }
  }

  @Test(
    "R11: 基準 Unknown の確定と一時消失が重なっても保持中の pane を含む tmux 順に残る",
    arguments: [AgentState.working, .question])
  func baselineResolutionUsesMissingPanePosition(_ destination: AgentState) {
    var stabilizer = PaneDisplayStateStabilizer()
    let inputs = [
      [pane("%1", .unknown), pane("%2", .unknown), pane("%3", .unknown)],
      [pane("%1", .unknown), pane("%2", .unknown), pane("%3", destination)],
      [pane("%1", .unknown), pane("%2", destination)],
      [pane("%1", .unknown), pane("%2", destination), pane("%3", destination)],
      [pane("%1", destination), pane("%2", destination), pane("%3", destination)],
    ]
    var previous: [PaneDisplayState] = []
    for (step, input) in inputs.enumerated() {
      let current = stabilizer.observe(input, at: start.advanced(by: .seconds(step)))
      expectStableTies(previous, current, seed: 0, step: step)
      #expect(current.map(\.paneID.rawValue) == ["%1", "%2", "%3"], "step=\(step)")
      #expect(current.map(\.changedAt) == [nil, nil, nil], "step=\(step)")
      previous = current
    }
    #expect(previous.map(\.state) == Array(repeating: destination, count: 3))
  }

  @Test(
    "基準の全 pane が残る40手の一時消失と初回確定の後は同じ Overview 順位の群が tmux 順",
    arguments: Array(1...256))
  func temporaryAbsencesAndInitialResolutionsEndInTmuxOrder(seed: Int) {
    var random = OrderRandomGenerator(state: UInt64(seed))
    var stabilizer = PaneDisplayStateStabilizer()
    let ids = (1...6).map { "%\($0)" }
    var states = Array(repeating: AgentState.unknown, count: ids.count)
    let destinations: [AgentState] = [
      .working, .question, .completed, .permission, .working, .error,
    ]
    var previous = stabilizer.observe(ids.map { pane($0, .unknown) }, at: start)

    for step in 1...40 {
      let input = ids.enumerated().compactMap { index, id -> PaneAgentState? in
        if states[index] == .unknown, random.index(8) == 0 || step == 40 {
          states[index] = destinations[index]
        }
        // 毎偶数手で全 pane を観測し、消失期限による削除と初出への置き換えを混ぜない。
        if step % 2 != 0, random.index(3) == 0 { return nil }
        return pane(id, states[index])
      }
      let current = stabilizer.observe(input, at: start.advanced(by: .seconds(step)))
      expectStableTies(previous, current, seed: seed, step: step)
      #expect(current.count == ids.count, "seed=\(seed), step=\(step)")
      #expect(current.allSatisfy { $0.changedAt == nil }, "seed=\(seed), step=\(step)")
      previous = current
    }

    for attention in [false, true] {
      let expected = ids.enumerated().filter {
        (destinations[$0.offset].worktreeCategory == .needsAttention) == attention
      }.map(\.element)
      let actual = previous.filter { ($0.category == .needsAttention) == attention }
      #expect(actual.map(\.paneID.rawValue) == expected, "seed=\(seed), step=40")
    }
    for (id, destination) in zip(ids, destinations) {
      #expect(
        previous.first { $0.paneID.rawValue == id }?.state == destination,
        "seed=\(seed), step=40, pane=\(id)")
    }
  }

  private func expectStableTies(
    _ previous: [PaneDisplayState], _ current: [PaneDisplayState], seed: Int, step: Int
  ) {
    let positions = Dictionary(
      uniqueKeysWithValues: current.enumerated().map { ($0.element.paneID, $0.offset) })
    for (offset, left) in previous.enumerated() {
      guard let leftIndex = positions[left.paneID] else { continue }
      let newLeft = current[leftIndex]
      guard sameOverviewRank(newLeft, left) else { continue }
      for right in previous.dropFirst(offset + 1) {
        guard sameOverviewRank(right, left),
          let rightIndex = positions[right.paneID]
        else { continue }
        let newRight = current[rightIndex]
        guard sameOverviewRank(newRight, right) else {
          continue
        }
        #expect(
          leftIndex < rightIndex,
          """
          seed=\(seed), step=\(step), pair=\(left.paneID.rawValue),\(right.paneID.rawValue)
          previous=\(previous.map(\.paneID.rawValue)), current=\(current.map(\.paneID.rawValue))
          """
        )
      }
    }
  }

  private func sameOverviewRank(_ lhs: PaneDisplayState, _ rhs: PaneDisplayState) -> Bool {
    (lhs.category == .needsAttention) == (rhs.category == .needsAttention)
      && lhs.changedAt == rhs.changedAt
  }

  private func pane(_ id: String, _ state: AgentState) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      observation: AgentStateObservation(
        state: state, adapterID: AgentAdapterID(rawValue: "test"), observedAt: .distantPast,
        unknownReason: state == .unknown ? .signalMissing : nil))
  }
}

private struct OrderRandomGenerator {
  var state: UInt64

  mutating func index(_ upperBound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 32) % UInt64(upperBound))
  }
}
