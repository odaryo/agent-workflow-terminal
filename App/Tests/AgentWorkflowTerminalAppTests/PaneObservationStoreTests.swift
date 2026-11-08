import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("Issue #387 初回の観測完了")
struct PaneObservationStoreTests {
  @Test("未完の snapshot だけでは未観測のまま", arguments: [true, false])
  func incompleteObservation(isEmpty: Bool) throws {
    var observation = PaneObservationStore.Observed()
    let panes = isEmpty ? [] : [paneState]
    for _ in 0..<2 {
      observation.receivePaneStates(.init(panes: panes, isComplete: false))
      #expect(observation.paneStates == nil)
      #expect(observation.latestPaneStates == panes)
      let input = try input(observation)
      #expect(!input.isObserved)
      #expect(makeTabSummaries([input]).first?.rows == [.notObserved])
    }
  }

  @Test("初回完了後は未完の snapshot でも観測済みのまま")
  func completedObservation() throws {
    var observation = PaneObservationStore.Observed()
    observation.receivePaneStates(.init(panes: [], isComplete: false))
    observation.receivePaneStates(.init(panes: [], isComplete: true))

    #expect(try input(observation).isObserved)
    #expect(observation.paneStates == [])
    #expect(makeTabSummaries([try input(observation)]).first?.rows == [.noAgentPane])

    observation.receivePaneStates(.init(panes: [paneState], isComplete: false))

    #expect(try input(observation).isObserved)
    #expect(observation.paneStates == [paneState])
    #expect(observation.latestPaneStates == [paneState])
  }

  @Test("観測を作り直した session と別 session は初回完了を引き継がない")
  func freshObservation() throws {
    var observation = PaneObservationStore.Observed()
    observation.receivePaneStates(.init(panes: [], isComplete: true))
    #expect(try input(observation).isObserved)

    var other = PaneObservationStore.Observed()
    other.receivePaneStates(.init(panes: [], isComplete: false))
    #expect(try !input(other).isObserved)

    observation = PaneObservationStore.Observed()
    observation.receivePaneStates(.init(panes: [], isComplete: false))
    #expect(try !input(observation).isObserved)
  }

  private var paneState: PaneAgentState {
    PaneAgentState(id: PaneID(rawValue: "%2"), state: .working, lastUpdatedAt: .distantPast)
  }

  private func input(_ observation: PaneObservationStore.Observed) throws -> OverviewWorktreeInput {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    return OverviewWorktreeInput(
      session: .primary(identity), observation: observation, mainPane: nil)
  }
}
