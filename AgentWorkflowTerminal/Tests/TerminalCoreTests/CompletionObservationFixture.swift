import Foundation
import TerminalCore

struct CompletionObservationFixture {
  private var tracker = PaneTaskCompletionTracker()
  private var turnEnds: [PaneID: Date] = [:]

  mutating func update(
    paneID: PaneID, completion: PaneSummaryEntry<AgentStampedValue>, agentState: AgentState?,
    observedAt: Date? = nil
  ) -> PaneTaskCompletionDisplay {
    if agentState == .idle || agentState == .completed, let observedAt {
      turnEnds[paneID] = observedAt
    }
    return tracker.update(
      paneID: paneID, completion: completion, agentState: agentState,
      lastTurnEndObservedAt: turnEnds[paneID])
  }

  mutating func forget(paneID: PaneID) {
    turnEnds.removeValue(forKey: paneID)
    tracker.forget(paneID: paneID)
  }
}
