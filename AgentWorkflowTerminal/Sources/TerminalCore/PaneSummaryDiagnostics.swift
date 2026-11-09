public struct PaneSummaryDiagnostic: Sendable, Hashable {
  public enum Option: String, Sendable, Hashable {
    case status = "@awt_status"
    case completion = "@awt_done"
  }

  public let paneID: PaneID
  public let option: Option
  public let violation: PaneSummaryFormatViolation
  public var message: String {
    let correction =
      switch violation {
      case .missingTurnStart:
        "<agent-pid> turn=<エポックミリ秒> <token> の形式で書いてください。"
      case .invalidTurnStart:
        "turn= に正の10進数のエポックミリ秒を書いてください。"
      case .turnStartOutOfRange:
        "turn= に13桁のエポックミリ秒を書いてください。"
      case .blank:
        "空白だけでなく、PID と本文を書いてください。"
      case .missingAgentProcessID:
        "先頭に Agent の PID を10進数で書いてください。"
      case .missingSeparator:
        "各項目を半角空白で区切ってください。"
      case .agentProcessIDOutOfRange:
        "Agent の PID を1〜2147483647の範囲で書いてください。"
      case .emptyText:
        "末尾に空白だけでない本文を書いてください。"
      case .containsLineBreakOrControlCharacter:
        "改行や制御文字を取り除き、1行で書いてください。"
      }
    return "\(option.rawValue): \(correction)"
  }
}

public struct PaneSummaryDiagnosticTracker: Sendable {
  private var previousDiagnostics: Set<PaneSummaryDiagnostic> = []

  public init() {}

  public mutating func newDiagnostics(for summaries: [PaneSummary]) -> [PaneSummaryDiagnostic] {
    var candidates: [PaneSummaryDiagnostic] = []
    for summary in summaries {
      if case .discarded(.malformed(let violation)) = summary.status {
        candidates.append(
          PaneSummaryDiagnostic(paneID: summary.paneID, option: .status, violation: violation))
      }
      if case .discarded(.malformed(let violation)) = summary.completion {
        candidates.append(
          PaneSummaryDiagnostic(paneID: summary.paneID, option: .completion, violation: violation))
      }
    }
    let diagnostics = candidates.filter { !previousDiagnostics.contains($0) }
    previousDiagnostics = Set(candidates)
    return diagnostics
  }
}
