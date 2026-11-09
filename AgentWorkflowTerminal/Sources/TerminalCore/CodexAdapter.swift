import Foundation

/// Codex 0.152.1 が title に出す spinner / Action Required と画面の実測、および
/// 0.166.0 の trust 画面の実測だけを使う (Spikes/gate3/README.md §3.2、§4.1、§6.2、§11、
/// Issue #252、設計書 §12.8)。
public struct CodexAdapter: AgentAdapter {
  public let id = AgentAdapterID(rawValue: "codex")
  public let processNames: Set<String> = ["codex"]
  public init() {}

  public func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult {
    guard liveness != .absent else { return .absent }
    guard liveness == .alive else { return unknown(signals, reason: .livenessUnavailable) }
    // Issue #252、設計書 §12.8: 0.166.0 の trust 画面は Action Required を出さないため、
    // title より先に見る。Issue #645: 応答本文にも確認画面が引用されるため、文言だけでは判断待ちにしない。
    if let screen = signals.screenText {
      let lines = screen.components(separatedBy: .newlines).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if lines.contains("Folder access"),
        lines.contains("› 1. Trust and continue") || lines.contains("1. Trust and continue"),
        lines.last(where: { !$0.isEmpty }) == "enter continue · esc back"
      {
        return observation(.permission, signals)
      }
    }
    if let attention = attentionObservation(signals) {
      return attention
    }
    if hasWorkingSpinner(signals.paneTitle) {
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

  private func attentionObservation(_ signals: AgentSignals) -> AgentObservationResult? {
    guard signals.paneTitle.contains("Action Required") else { return nil }
    guard let screen = signals.screenText else {
      return unknown(signals, reason: .screenUnavailable, category: .needsAttention)
    }
    if screen.contains("Would you like to") || screen.contains("Press enter to confirm") {
      return observation(.permission, signals)
    }
    return unknown(signals, reason: .adapterUndetermined, category: .needsAttention)
  }

  private func hasWorkingSpinner(_ title: String) -> Bool {
    guard let first = title.unicodeScalars.first else { return false }
    return (0x2800...0x28FF).contains(first.value)
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
