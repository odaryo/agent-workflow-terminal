import TerminalCore

extension AgentState {
  /// 表示名は §12.2 の語彙。`completed` だけ状態名と表示名が違う (Ready for Review)。
  var displayLabel: String {
    switch self {
    case .working: "Working"
    case .question: "Question"
    case .permission: "Permission"
    case .completed: "Ready for Review"
    case .error: "Error"
    case .idle: "Idle"
    case .unknown: "Unknown"
    }
  }
}
