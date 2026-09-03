import Foundation

public struct CodexAdapter: AgentAdapter {
  public let id = AgentAdapterID(rawValue: "codex")
  public let processNames: Set<String> = ["codex"]
  public init() {}

  public func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult {
    guard liveness != .absent else { return .absent }
    guard liveness == .alive else { return unknown(signals, reason: .signalMissing) }
    guard !signals.isPaneInMode else { return unknown(signals, reason: .screenUnavailable) }
    if signals.paneTitle.contains("Action Required") {
      guard let screen = signals.screenText else {
        return unknown(signals, reason: .screenUnavailable, category: .needsAttention)
      }
      if screen.contains("Would you like to") || screen.contains("Press enter to confirm") {
        return observation(.permission, signals)
      }
      return unknown(signals, reason: .adapterUndetermined, category: .needsAttention)
    }
    if let first = signals.paneTitle.unicodeScalars.first,
      (0x2800...0x28FF).contains(first.value)
    {
      return observation(.working, signals)
    }
    guard let screen = signals.screenText else {
      return unknown(signals, reason: .screenUnavailable)
    }
    if screen.range(of: #"(?m)^\s*•\s(?!You have|Tip)"#, options: .regularExpression) != nil {
      return observation(.completed, signals)
    }
    if screen.contains("Ask Codex to do anything") { return observation(.idle, signals) }
    return unknown(signals, reason: .adapterUndetermined)
  }

  private func observation(_ state: AgentState, _ signals: AgentSignals) -> AgentObservationResult {
    .observation(AgentStateObservation(state: state, adapterID: id, observedAt: signals.observedAt))
  }

  private func unknown(
    _ signals: AgentSignals, reason: UnknownReason,
    category: WorktreeStateCategory? = nil
  ) -> AgentObservationResult {
    .observation(
      AgentStateObservation(
        state: .unknown, adapterID: id, observedAt: signals.observedAt,
        category: category, unknownReason: reason
      ))
  }
}
