import Adapters
import Foundation
import TerminalCore

/// 送信の可否と、送らなかった理由の文言 (設計書 §9.2.2 / §9.2.1)。
///
/// `DiffViewerModel` 本体から分けているのは、1ファイル・1型の行数上限に収めるため
/// (`DiffViewerModelGit.swift` と同じ理由)。
extension DiffViewerModel {
  enum PendingSend: Equatable {
    case single(DiffReviewCommentID)
    case batch([DiffReviewCommentID])

    /// `.batch` を集合として見るのは、同じ選択が UI の並び順で別要求に見えると連打が
    /// すり抜けるため。合成 `==` は配列比較なのでこの判定には使えない。
    func isSameRequest(as other: Self) -> Bool {
      switch (self, other) {
      case (.single(let lhs), .single(let rhs)): lhs == rhs
      case (.batch(let lhs), .batch(let rhs)): Set(lhs) == Set(rhs)
      case (.single, .batch), (.batch, .single): false
      }
    }
  }

  /// 未登録・登録先の消失のどちらでも、送る前にユーザーへ選ばせるための要求 (§12.7)。
  struct PaneSelectionRequest: Identifiable {
    let id = UUID()
    let worktree: WorktreeIdentity
    let candidates: [MainPaneCandidate]
    /// 登録が残っているが、その pane を送信先として使えない場合だけ入る。「ID ごと消えた」と
    /// 「ID は在るが別 pane」で文面を変えるため、`PaneID` へ潰さない。
    let absence: MainPaneAbsence?
    /// 送信操作の途中で選ばせている場合だけ入る。`nil` は送信先の選び直しだけを行う操作。
    let pending: PendingSend?
    /// 候補を観測したときの `#{pid}`。選ばれた候補と組にして登録を作る。
    let serverProcessID: Int32?
  }

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

/// 連打で同じコメントが2回貼られるのを止める、送信要求の短時間 coalescing (Issue #276)。
///
/// 進行中の送信を1つに直列化するだけでは足りない。1回の送信が撃つ tmux コマンド列は実測
/// 34〜36 ms (tmux 3.4、隔離 socket) で終わる一方、macOS の
/// `com.apple.mouse.doubleClickThreshold` は 0.8 秒なので、人のダブルクリックの2発目は
/// ほぼ必ず「完了後の新しい要求」として届く。
///
/// - Important: 記録するのは**注入が成功した時点だけ**。失敗の直後にユーザーが押し直すのは
///   正当な再試行であり、これを捨てると tmux が一時的に落ちていた場合に送り直せなくなる。
/// - Important: 判定には単調増加クロックを使う。`Date()` は NTP 補正で後ろへ飛び得るため、
///   閾値の判定には使えない (`markSent` の `Date()` は表示用の記録で判定に使っていない)。
struct DiffCommentSendCoalescer {
  /// ダブルクリック閾値 0.8 秒を含み、意図的な再送を妨げない程度に短い値。
  static let window = Duration.seconds(1)

  private let timeSource: any ContinuousTimeSource
  private var lastSuccess: (request: DiffViewerModel.PendingSend, at: ContinuousClock.Instant)?

  init(timeSource: any ContinuousTimeSource) {
    self.timeSource = timeSource
  }

  func shouldDrop(_ pending: DiffViewerModel.PendingSend) -> Bool {
    guard let lastSuccess, lastSuccess.request.isSameRequest(as: pending) else { return false }
    return timeSource.now < lastSuccess.at.advanced(by: Self.window)
  }

  mutating func recordSuccess(_ pending: DiffViewerModel.PendingSend) {
    lastSuccess = (pending, timeSource.now)
  }
}
