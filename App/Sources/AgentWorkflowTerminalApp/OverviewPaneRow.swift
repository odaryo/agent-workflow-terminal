import Adapters
import SwiftUI
import TerminalCore

/// Overview の pane 1行 (設計書 §13)。状態・名前・目的・現在地・タスク完了。
///
/// 目的の入力欄だけは行の選択 (pane への移動) に含めない。含めると、編集しようとしたクリックで
/// メイン window へ移ってしまう。
struct OverviewPaneRow: View {
  let pane: OverviewPane
  @ObservedObject var store: PaneObservationStore
  let reveal: () -> Void

  @State private var draft = ""
  @FocusState private var isEditing: Bool
  /// 書き込みに成功し、観測にまだ現れていない値。観測は最大で 2 秒 (+ キャッシュの 1 秒) 遅れて
  /// 届くので、確定直後に古い値へ戻って見えるのを防ぐ。
  @State private var written: String?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Button(action: reveal) {
          HStack(spacing: 6) {
            AgentStateIcon(presentation: presentation)
            Text(name).monospacedDigit().frame(minWidth: 44, alignment: .leading)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("この pane へ移動")
        // 記号と Text から label が合成されない (AX 属性に description が無かった、実測)。
        .accessibilityLabel("\(presentation.label) \(name)")

        TextField("目的", text: $draft)
          .textFieldStyle(.roundedBorder)
          .focused($isEditing)
          .onSubmit(submit)
          .onExitCommand { isEditing = false }
          .accessibilityLabel("目的")

        Button(action: reveal) {
          HStack(spacing: 6) {
            Text(pane.detail.status ?? "").foregroundStyle(.secondary).lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
            if pane.detail.isTaskCompleted {
              AgentStateIcon(presentation: .taskCompleted)
            }
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(statusAccessibilityLabel)
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .padding(.leading, 12)
    .onAppear { draft = shownPurpose }
    // 編集中は観測で上書きしない。2 秒ごとの観測で打ちかけの文字が消える。
    // 書いた値と一致するかでは待たない。観測が書いた値と違う形で届いたとき (tmux の版による
    // escape の差など) に、書いた値が永久に表示に残る。
    .onChange(of: pane.detail.purpose) { _, observed in
      written = nil
      if !isEditing { draft = observed ?? "" }
    }
    .onChange(of: isEditing) { _, editing in
      // 確定せずに離れたら観測の値へ戻す。戻さないと、書かれていない値が書かれたように残る。
      if !editing { draft = shownPurpose }
    }
  }

  private var presentation: AgentStatePresentation {
    AgentStatePresentation(state: pane.display.state, category: pane.display.category)
  }

  private var statusAccessibilityLabel: String {
    let completed = pane.detail.isTaskCompleted ? AgentStatePresentation.taskCompleted.label : nil
    return [pane.detail.status, completed].compactMap(\.self).joined(separator: " ")
  }

  private var name: String {
    paneShortName(paneID: pane.paneID, isMain: pane.isMain, location: pane.detail.location)
  }

  private var shownPurpose: String {
    written ?? pane.detail.purpose ?? ""
  }

  private func submit() {
    let text = draft
    Task {
      if let failure = await store.setPurpose(text, of: pane.paneID) {
        error = Self.describe(failure)
        // 確定 (Return) でフォーカスが外れ、未確定の値は観測値へ戻されている (実測)。直すために
        // 打ち直させないよう、拒否された値を入力欄へ戻す。
        draft = text
        isEditing = true
        return
      }
      error = nil
      written = text.allSatisfy(\.isWhitespace) ? "" : text
      isEditing = false
    }
  }

  private static func describe(_ error: TmuxPanePurposeWriterError) -> String {
    switch error {
    case .containsLineBreakOrControlCharacter: "目的は1行で、制御文字を含められません。"
    case .endsWithSemicolon: "目的の末尾に ; は置けません (tmux がコマンドの区切りとして読みます)。"
    case .tooLong(let byteCount, let limit): "目的が長すぎます (\(byteCount) / \(limit) バイト)。"
    case .invalidPaneID(let pane): "pane ID が不正です: \(pane.rawValue)"
    case .tmux(let failure): "tmux への書き込みに失敗しました: \(failure)"
    }
  }
}

/// Overview の行と通知で同じ pane の呼び名を使う (§13)。
func paneShortName(paneID: PaneID, isMain: Bool, location: PaneLocation?) -> String {
  if isMain { return "メイン" }
  guard let location else { return paneID.rawValue }
  return "\(location.windowIndex).\(location.paneIndex)"
}
