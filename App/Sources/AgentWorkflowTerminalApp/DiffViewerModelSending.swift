import Adapters
import Foundation
import TerminalCore

/// 送信の可否と、送らなかった理由の文言 (設計書 §9.2.2 / §9.2.1)。
///
/// `DiffViewerModel` 本体から分けているのは、1ファイル・1型の行数上限に収めるため
/// (`DiffViewerModelGit.swift` と同じ理由)。
extension DiffViewerModel {
  /// 送信操作を無効にする理由。`nil` は「状態では止めない」で、未登録のときも `nil`
  /// (送信先を選ぶのが先で、状態はその後に見る)。UI と `send` が同じ判定を通すための入口。
  func sendBlock(
    registeredPane: PaneID?,
    agentPaneStates: [PaneAgentState]?
  ) -> DiffCommentSendBlock? {
    guard let registeredPane else { return nil }
    guard
      case .blocked(let block) = DiffCommentSendGate.sendability(
        toPane: registeredPane, states: agentPaneStates)
    else { return nil }
    return block
  }

  /// 送信できない理由と、次に何をすれば送れるようになるかを書く (§9.2.2)。
  static func message(for block: DiffCommentSendBlock, pane: PaneID) -> String {
    switch block {
    case .paneState(let state):
      return
        "送信先 pane \(pane.rawValue) は \(state.displayLabel) のため送っていません。"
        + "先に pane 側の処理を進めてから送信してください。コメントは保持しています。"
    case .stateUnobserved:
      return
        "送信先 pane \(pane.rawValue) の Agent 状態を観測できていないため送っていません "
        + "(Agent が動いていない pane の可能性があります)。コメントは保持しています。"
    case .observationUnavailable:
      // pane のせいにしない。観測経路そのものが無い (到達不能な worktree 等)。
      return
        "この worktree は到達できないため pane の状態を観測していません。送っていません。"
        + "コメントは保持しています。"
    }
  }

  /// 拒否の理由ごとに文言を変える。`TmuxTextInjectionError` の分類はユーザーが取る復旧操作の
  /// 違いに対応しているため、まとめると復旧できない (`TmuxTextInjection` の doc 参照)。
  static func message(for failure: MainPaneInjectionFailure) -> String {
    switch failure {
    case .tmuxUnavailable:
      return "tmux を利用できないため送っていません。"
    case .destinationChanged(let registration):
      return
        "送信先 pane \(registration.pane.rawValue) は、選んだ時点とは別の pane になっています "
        + "(1バイトも届いていません)。送信先を選び直してください。"
    case .rejected(let error):
      return message(for: error)
    }
  }

  /// 注入層が拒否した理由ごとの文言。分岐が `MainPaneInjectionFailure` 側と別関数なのは、
  /// 1つにまとめると cyclomatic complexity の上限を超えるため。
  private static func message(for error: TmuxTextInjectionError) -> String {
    switch error {
    case .unsafeControlCharacter(let scalar, let offset):
      let code = String(format: "U+%04X", scalar.value)
      return
        "本文に貼り付けできない制御文字があります: 先頭から \(offset + 1) 番目の Unicode scalar が \(code)。"
        + "bracketed paste を抜け得るため送っていません。文面は自動修正しません。"
    case .paneInMode(let pane, let mode):
      let name = mode.isEmpty ? "(mode 名を読み直せませんでした。既に抜けた可能性があります)" : mode
      return
        "pane \(pane.rawValue) が \(name) 中のため送っていません (1バイトも届いていません)。"
        + "mode を抜けてから送り直してください。"
    case .paneInputDisabled(let pane):
      return
        "pane \(pane.rawValue) は入力が無効 (select-pane -d) のため送っていません "
        + "(1バイトも届いていません)。入力を有効に戻してください。"
    case .paneIdentityMismatch(let pane):
      // `MainPaneCoordinator.inject` が `.destinationChanged` へ写すので通常ここへは来ない。
      return
        "pane \(pane.rawValue) は登録したときの pane ではなくなっています "
        + "(1バイトも届いていません)。送信先を選び直してください。"
    case .serverNotRunning:
      return "tmux server が動いていないため送っていません (1バイトも届いていません)。"
    case .paneNotFound(let pane):
      return "pane \(pane.rawValue) が見つかりません。送信先を選び直してください。"
    case .invalidPaneID(let pane):
      return "pane ID の形式が不正です: \(pane.rawValue)"
    case .temporaryFileCreationFailed(let path):
      return "注入用の一時ファイルを作れませんでした: \(path)"
    case .tmux(let error):
      return "tmux の実行に失敗しました: \(error)"
    }
  }
}
