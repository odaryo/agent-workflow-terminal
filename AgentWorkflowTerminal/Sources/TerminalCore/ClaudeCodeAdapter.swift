import Foundation

/// Claude Code 2.1.259 の画面と出力活動の実測だけを使う
/// (Spikes/gate3/README.md §3、§6.1、§11)。title は状態信号として使わない。
public struct ClaudeCodeAdapter: AgentAdapter {
  public let id = AgentAdapterID(rawValue: "claude-code")
  public let processNames: Set<String> = ["claude"]
  public init() {}

  public func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult {
    guard liveness != .absent else { return .absent }
    guard liveness == .alive else { return unknown(signals, reason: .livenessUnavailable) }
    guard let screen = signals.screenText else {
      return unknown(signals, reason: .screenUnavailable)
    }
    if screen.contains("Do you want to ") || screen.contains("Esc to cancel · Tab to amend") {
      return observation(.permission, signals)
    }
    if screen.contains("Enter to select ·") && screen.contains("Type something.") {
      return observation(.question, signals)
    }
    let hasEmptyInputPrompt =
      screen.range(of: #"(?m)^❯[  ]*$"#, options: .regularExpression) != nil
    if let elapsed = signals.secondsSinceScreenChange, elapsed <= 1 {
      return observation(.working, signals)
    }
    if hasEmptyInputPrompt && screen.contains("Claude Code v") && screen.contains("mode on")
      && !screen.contains("⏺") && signals.secondsSinceScreenChange.map({ $0 > 1 }) == true
    {
      return observation(.idle, signals)
    }
    if hasEmptyInputPrompt, screen.contains("mode on"),
      screen.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
    {
      return observation(.completed, signals)
    }
    if signals.secondsSinceScreenChange == nil {
      return unknown(signals, reason: .signalMissing)
    }
    return unknown(signals, reason: .adapterUndetermined)
  }

  private func observation(_ state: AgentState, _ signals: AgentSignals) -> AgentObservationResult {
    .observation(AgentStateObservation(state: state, adapterID: id, observedAt: signals.observedAt))
  }

  private func unknown(_ signals: AgentSignals, reason: UnknownReason) -> AgentObservationResult {
    .observation(
      AgentStateObservation(
        state: .unknown, adapterID: id, observedAt: signals.observedAt, unknownReason: reason
      ))
  }
}
