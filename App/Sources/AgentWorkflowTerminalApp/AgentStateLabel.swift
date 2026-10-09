import SwiftUI
import TerminalCore

extension AgentState {
  /// 表示名は §12.2 の語彙。`completed` だけ状態名と表示名が違う — pane の応答終了であって、
  /// タスク完了 (§12.7) ではない (§5.3)。
  var displayLabel: String {
    switch self {
    case .working: "Working"
    case .question: "Question"
    case .permission: "Permission"
    case .completed: "応答終了"
    case .error: "Error"
    case .idle: "Idle"
    case .unknown: "Unknown"
    }
  }
}

/// 設計書 §5.3 の記号・色の対応表。Task Tab と Overview はこれだけを使う。
///
/// 色は補助であり、形だけで状態を区別できるようにする (§5.3)。同じ色の状態どうしも
/// 形は必ず変える。
struct AgentStatePresentation: Equatable {
  let symbol: String
  let color: Color
  /// accessibility label。
  let label: String

  /// - Important: `unknown` でも大分類が `needsAttention` なら Unknown の形にしない。adapter が
  ///   「人間の対応が要る」とだけ判定できた状態 (§12.4.3) を、注意の要らない Unknown と同じ形で
  ///   見せると見落とされる。
  init(state: AgentState, category: WorktreeStateCategory) {
    switch state {
    case .working: self.init("ellipsis.circle.fill", .accentColor, state.displayLabel)
    case .question: self.init("questionmark.bubble.fill", .orange, state.displayLabel)
    case .permission: self.init("hand.raised.fill", .orange, state.displayLabel)
    case .error: self.init("exclamationmark.octagon.fill", .red, state.displayLabel)
    case .completed: self.init("checkmark.circle", .green, state.displayLabel)
    case .idle: self.init("pause.circle", .gray, state.displayLabel)
    case .unknown where category == .needsAttention:
      self.init("exclamationmark.bubble.fill", .orange, "要対応 (種別不明)")
    case .unknown: self.init("circle.dashed", .gray, state.displayLabel)
    }
  }

  /// タスク完了 (§12.7) は状態と別の列に出す。pane の状態の記号と重ねない。
  static let taskCompleted = Self("checkmark.seal.fill", .green, "タスク完了")

  /// 到達不能・観測失敗のタブ。状態を観測していないので、状態の記号を流用しない (§12.3)。
  static func unobserved(_ label: String) -> Self {
    Self("exclamationmark.triangle", .gray, label)
  }

  private init(_ symbol: String, _ color: Color, _ label: String) {
    self.symbol = symbol
    self.color = color
    self.label = label
  }
}

struct AgentStateIcon: View {
  let presentation: AgentStatePresentation

  var body: some View {
    Image(systemName: presentation.symbol)
      .foregroundStyle(presentation.color)
      .accessibilityLabel(presentation.label)
  }
}
