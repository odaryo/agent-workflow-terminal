import SwiftUI
import TerminalCore

/// 選択中のファイルに付いたコメントの入力・一覧・送信 (設計書 §9.2)。
struct DiffCommentPanel: View {
  @ObservedObject var model: DiffViewerModel
  @ObservedObject var mainPane: MainPaneCoordinator
  let worktree: WorktreeIdentity
  let agentPaneStates: () -> [PaneAgentState]?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("コメント").fontWeight(.medium)
      editor
      Divider()
      list
    }
    .padding(8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var editor: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(selectionLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(text: $model.commentDraft)
        .font(.callout)
        .frame(height: 80)
        .border(Color.secondary.opacity(0.3))
      Button("コメントを追加") { model.addComment() }
        .disabled(model.lineSelection == nil || model.commentDraft.isEmpty)
    }
  }

  private var selectionLabel: String {
    guard let selection = model.lineSelection else {
      return "行を選んでください (click で1行 / shift + click で範囲)"
    }
    let side = selection.side == .old ? "old" : "new"
    let range =
      selection.range.start == selection.range.end
      ? "\(selection.range.start)" : "\(selection.range.start)-\(selection.range.end)"
    return "選択中: \(selection.file.path) \(side) \(range)"
  }

  @ViewBuilder
  private var list: some View {
    if model.currentFileComments.isEmpty {
      Text("このファイルのコメントはありません").font(.caption).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    } else {
      List {
        ForEach(model.currentFileComments) { comment in
          row(comment)
        }
      }
      .listStyle(.plain)
    }
  }

  private func row(_ comment: DiffReviewComment) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(Self.anchorLabel(comment.anchor))
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
      Text(comment.body).font(.caption)
      // 「Agent が受け取った」とは書かない。注入は貼り付けであって実行ではない (§9.2.1 制約1)。
      if let sentAt = comment.sentAt {
        Text("貼り付け済み \(sentAt.formatted(date: .omitted, time: .standard))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Button("送信") {
          Task {
            await model.requestSend(
              .single(comment.id), worktree: worktree, mainPane: mainPane,
              agentPaneStates: agentPaneStates())
          }
        }
        .disabled(model.isSending || isSendBlocked)
        Button("削除") { model.removeComment(comment.id) }
        Spacer(minLength: 0)
      }
      .buttonStyle(.link)
      .font(.caption)
    }
    .padding(.vertical, 2)
  }

  /// 理由は §9.2.2 の banner が1箇所で出すので、ここは無効化だけ行う。
  private var isSendBlocked: Bool {
    model.sendBlock(
      registeredPane: mainPane.registeredPane(for: worktree),
      agentPaneStates: agentPaneStates()) != nil
  }

  private static func anchorLabel(_ anchor: DiffCommentAnchor) -> String {
    let side = anchor.side == .old ? "old" : "new"
    let range =
      anchor.lines.start == anchor.lines.end
      ? "\(anchor.lines.start)" : "\(anchor.lines.start)-\(anchor.lines.end)"
    return "\(anchor.origin.label) / \(side) \(range)"
  }
}

/// メインpane (= 実装Agent pane) をユーザーに選ばせる (設計書 §12.7)。候補が1つでも既定選択を
/// 置かない。「Agent」の印は選択の材料であって、選択そのものはユーザーが行う。
struct MainPanePicker: View {
  let request: DiffViewerModel.PaneSelectionRequest
  let choose: (MainPaneCandidate) -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("送信先の pane を選ぶ").fontWeight(.medium)
      if let absence = request.absence {
        Label(Self.absenceMessage(absence), systemImage: "exclamationmark.triangle")
          .font(.caption)
      }
      if request.candidates.isEmpty {
        Text("この worktree の tmux session に生存 pane がありません。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        List(request.candidates) { candidate in
          Button {
            choose(candidate)
          } label: {
            HStack(spacing: 6) {
              Text(candidate.pane.id.rawValue).font(.caption.monospaced())
              Text(candidate.pane.currentCommand).font(.caption)
              if candidate.isAgent {
                Text("Agent").font(.caption2).foregroundStyle(.blue)
              }
              Spacer(minLength: 0)
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
        }
        .frame(minHeight: 140)
      }
      HStack {
        Spacer()
        Button("キャンセル", action: cancel)
      }
    }
    .padding(12)
    .frame(width: 380)
  }

  /// `paneReplaced` で「存在しません」と書かない。その `%N` はすぐ下の候補一覧に並んでいる。
  private static func absenceMessage(_ absence: MainPaneAbsence) -> String {
    switch absence {
    case .paneGone(let pane):
      "登録されていた pane \(pane.rawValue) は現在存在しません。選び直してください。"
    case .paneReplaced(let pane):
      "登録されていた pane \(pane.rawValue) は、同じ ID の別の pane に置き換わっています "
        + "(tmux server の再起動など)。選び直してください。"
    case .identityUnverifiable(let pane):
      // 「別 pane になった」と断定しない。確かめられなかっただけ。
      "登録されていた pane \(pane.rawValue) が同じ pane のままか確かめられませんでした "
        + "(tmux server の同一性を読めていません)。選び直してください。"
    }
  }
}
