import Foundation

/// process 観測だけでは Working / Idle を区別できなかったため、状態を推測しない
/// (Spikes/gate3/README.md §6.3、§7.4)。
public struct ProcessDetectionFallbackAdapter: AgentAdapter {
  public let id = AgentAdapterID(rawValue: "process-detection")
  public let processNames: Set<String>
  public init(processNames: Set<String>) { self.processNames = processNames }

  public func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult {
    guard liveness != .absent else { return .absent }
    let reason: UnknownReason =
      liveness == .undetermined ? .livenessUnavailable : .adapterUndetermined
    return .observation(
      AgentStateObservation(
        state: .unknown, adapterID: id, observedAt: signals.observedAt, unknownReason: reason
      ))
  }
}

public struct AgentAdapterCandidate: Sendable {
  public let adapter: any AgentAdapter
  public let liveness: AgentLiveness
  public init(adapter: any AgentAdapter, liveness: AgentLiveness) {
    self.adapter = adapter
    self.liveness = liveness
  }
}

public enum AgentAdapterResolver {
  public static func resolve(
    pane: PaneSnapshot, candidates: [AgentAdapterCandidate], fallback: any AgentAdapter
  ) -> any AgentAdapter {
    guard !pane.isDead else { return fallback }
    return candidates.first(where: { $0.liveness == .alive })?.adapter ?? fallback
  }
}
