import Foundation
import Testing

@testable import TerminalCore

@Suite("§9.2.2 Diff レビューコメントの送信可否")
struct DiffCommentSendGateTests {
  private static let pane = PaneID(rawValue: "%1")

  private static func state(_ state: AgentState, pane: PaneID = pane) -> PaneAgentState {
    PaneAgentState(id: pane, state: state, lastUpdatedAt: Date(timeIntervalSince1970: 1))
  }

  @Test("許可するのは idle と completed だけ", arguments: AgentState.allCases)
  func partitionsEveryAgentState(_ state: AgentState) {
    let sendability = DiffCommentSendGate.sendability(
      toPane: Self.pane, states: [Self.state(state)])
    // 集合の外から見た期待値をここに書く。`sendableStates` を参照すると実装の写しになる。
    if state == .idle || state == .completed {
      #expect(sendability == .allowed)
    } else {
      #expect(sendability == .blocked(.paneState(state)))
    }
  }

  @Test("状態エントリが無い pane へは送らない")
  func blocksWhenTheDestinationHasNoObservedState() {
    // 素のシェル pane は `.absent` になり `WorktreePaneAgentStateFeed` の出力に現れない。
    #expect(
      DiffCommentSendGate.sendability(toPane: Self.pane, states: [])
        == .blocked(.stateUnobserved))
    #expect(
      DiffCommentSendGate.sendability(
        toPane: Self.pane, states: [Self.state(.idle, pane: PaneID(rawValue: "%2"))])
        == .blocked(.stateUnobserved))
  }

  @Test("観測経路が無い場合と、経路はあるが Agent pane が無い場合を分ける")
  func separatesMissingObservationPathFromEmptyObservation() {
    // `nil` は到達不能な worktree などで観測経路そのものが無い状態。pane のせいにしない。
    #expect(
      DiffCommentSendGate.sendability(toPane: Self.pane, states: nil)
        == .blocked(.observationUnavailable))
    #expect(
      DiffCommentSendGate.sendability(toPane: Self.pane, states: [])
        == .blocked(.stateUnobserved))
  }

  @Test("送信先以外の pane の状態で可否が変わらない")
  func looksOnlyAtTheDestinationPane() {
    let states = [
      Self.state(.working, pane: PaneID(rawValue: "%0")),
      Self.state(.completed),
      Self.state(.permission, pane: PaneID(rawValue: "%2")),
    ]
    #expect(DiffCommentSendGate.sendability(toPane: Self.pane, states: states) == .allowed)
  }

  @Test("許可集合は idle と completed の2つ")
  func exposesTheAllowedSetInOnePlace() {
    #expect(DiffCommentSendGate.sendableStates == [.idle, .completed])
  }
}
