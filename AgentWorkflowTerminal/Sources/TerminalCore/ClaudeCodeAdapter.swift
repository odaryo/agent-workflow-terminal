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
    guard !signals.isPaneInMode else { return unknown(signals, reason: .screenUnavailable) }
    guard let screen = signals.screenText else {
      return unknown(signals, reason: .screenUnavailable)
    }
    if screen.contains("Do you want to ") || screen.contains("Esc to cancel · Tab to amend") {
      return observation(.permission, signals)
    }
    if screen.contains("Enter to select ·") && screen.contains("Type something.") {
      return observation(.question, signals)
    }
    if screen.contains("Claude Code v") && screen.contains("mode on")
      && !screen.contains("⏺")
    {
      return observation(.idle, signals)
    }
    let hasEmptyInputPrompt =
      screen.range(of: #"(?m)^❯[  ]*$"#, options: .regularExpression) != nil
    if hasEmptyInputPrompt,
      screen.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
    {
      return observation(.completed, signals)
    }
    if let elapsed = signals.secondsSinceOutput, elapsed <= 2 {
      return observation(.working, signals)
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
