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
  let showsDisplayedMark: Bool
  let sessionMenu: OverviewSessionMenu?
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
            if pane.isMain {
              Text("メイン")
            }
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("この pane へ移動")
        // 記号と Text から label が合成されない (AX 属性に description が無かった、実測)。
        // VoiceOver と UI 確認のハーネスが行を区別できるよう、見た目から消した ID も name に残す。
        .accessibilityLabel("\(showsDisplayedMark ? "表示中 " : "")\(presentation.label) \(name)")
        .contextMenu {
          rowMenu
        }

        // 目的が空のときの title は placeholder ではなく重ねた Text で出す。placeholder の既定色 (約 25%) は
        // 読みにくく、prompt の Text に付けた色はサイドバーの実画面で効かなかった (#794。画面外の描画では
        // 効いたので、原因は切り分けていない)。色は入力済みの目的 (labelColor) と見分けが付く secondary。
        // 編集中は重ねず placeholder に任せる。IME の未確定文字は draft に入らないので、重ねたままだと変換中の
        // 文字と title が重なる (実画面で確認)。
        TextField(
          "目的", text: $draft,
          prompt: Text(titleFallback == nil ? pane.detail.title ?? "目的" : "")
        )
        .textFieldStyle(.roundedBorder)
        .focused($isEditing)
        .onSubmit(submit)
        .onExitCommand { isEditing = false }
        // overlay より前に置く。後ろに置くと重ねた title にも「目的」の label が付き、title が読めなくなる (実測)。
        .accessibilityLabel("目的")
        .overlay(alignment: .leading) {
          if let titleFallback {
            // 11pt は実画面のサイドバーで placeholder の左端と一致する値 (macOS 27、スクリーンショットの画素で
            // 比べた)。画面外の描画で測った 6pt は実画面と 5pt ずれた。
            Text(titleFallback).foregroundStyle(.secondary).lineLimit(1)
              .padding(.leading, 11).padding(.trailing, 6)
              .allowsHitTesting(false)
          }
        }
        .frame(maxWidth: .infinity)

        // 空の現在地にも幅を割くと、目的欄が狭いサイドバーで数文字分まで縮む (#604)。
        if pane.detail.status != nil || pane.detail.isTaskCompleted {
          Button(action: reveal) {
            HStack(spacing: 6) {
              if let status = pane.detail.status {
                Text(status).foregroundStyle(.secondary).lineLimit(1)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              if pane.detail.isTaskCompleted {
                AgentStateIcon(presentation: .taskCompleted)
              }
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(statusAccessibilityLabel)
          .contextMenu {
            rowMenu
          }
        }
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .listRowBackground(showsDisplayedMark ? OverviewDisplayedRowBackground() : nil)
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

  @ViewBuilder
  private var rowMenu: some View {
    OverviewPaneIDItems(panes: [pane])
    if let sessionMenu {
      Divider()
      sessionMenu
    }
  }

  private var titleFallback: String? {
    draft.isEmpty && !isEditing ? pane.detail.title : nil
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
      written = PaneSummaryFormatViolation.isInvisibleOnly(text) ? "" : text
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

func paneIDMenuTitle(paneID: PaneID, isMain: Bool, location: PaneLocation?) -> String {
  let name = paneShortName(paneID: paneID, isMain: false, location: location)
  return "pane \(name)\(isMain ? " (メイン)" : "")"
}
