import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("Issue #828 引き渡し済みの印")
struct AgentStatePresentationTests {
  private static let allStates: [AgentState] = [
    .working, .question, .permission, .completed, .error, .idle, .unknown,
  ]

  @Test("応答終了と Idle だけが引き渡し済みの印になる", arguments: allStates)
  func handedOffReplacesOnlyTurnEndingStates(state: AgentState) {
    let plain = AgentStatePresentation(state: state, category: .idle)
    let handedOff = AgentStatePresentation(state: state, category: .idle, isHandedOff: true)
    if state == .completed || state == .idle {
      #expect(handedOff.label == "引き渡し済み")
      #expect(handedOff.symbol == "arrowshape.turn.up.right.circle")
    } else {
      #expect(handedOff == plain)
    }
  }

  @Test("要対応 (種別不明) は引き渡し済みでも要対応の印のまま")
  func needsAttentionUnknownIsKept() {
    let plain = AgentStatePresentation(state: .unknown, category: .needsAttention)
    let handedOff = AgentStatePresentation(
      state: .unknown, category: .needsAttention, isHandedOff: true)
    #expect(handedOff == plain)
  }

  @Test("引き渡し済みの記号は他のどの印とも違う")
  func handedOffSymbolIsDistinct() {
    let handedOff = AgentStatePresentation(state: .idle, category: .idle, isHandedOff: true)
    var others = Self.allStates.map { AgentStatePresentation(state: $0, category: .idle).symbol }
    others.append(AgentStatePresentation(state: .unknown, category: .needsAttention).symbol)
    others.append(AgentStatePresentation.taskCompleted.symbol)
    others.append(AgentStatePresentation.unobserved("x").symbol)
    #expect(!others.contains(handedOff.symbol))
  }
}
