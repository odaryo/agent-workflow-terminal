import Adapters
import TerminalCore

/// 登録解除の確認ダイアログに出す内容と、「削除して解除」が消す対象 (設計書 §16.1)。
/// 消す session は確認時点で決め、確認後に現れた session は巻き込まない。
struct ProjectUnregisterReview: Identifiable {
  let project: RegisteredProject
  let sessions: [TmuxSessionName]
  /// 非 `nil` なら session を一覧できていない。理由は本文に出す。
  let sessionListingFailure: String?
  /// 非 `nil` なら保存データを読めていない。task worktree の session を特定できない可能性があり、
  /// 記録を残すため `store` も消さない。
  let inventoryLoadFailure: String?
  /// `nil` は Application Support を使えない起動。消すデータが無い。
  let store: WorktreeInventoryStore?

  var id: WorktreeIdentity { project.commonDirectory }

  var title: String { "「\(project.displayName)」の登録を解除" }

  var message: String {
    var lines: [String] = []
    if let sessionListingFailure {
      lines.append("tmux の session を一覧できないため、session は削除しません。(\(sessionListingFailure))")
    } else if sessions.isEmpty {
      lines.append("削除する tmux session はありません。")
    } else {
      lines.append("削除する tmux session:")
      lines.append(contentsOf: sessions.map { "・\($0.rawValue)" })
      lines.append("session 内で動いている Agent やコマンドも終了します。")
    }
    if let inventoryLoadFailure {
      lines.append(
        "保存データを読めないため、一部の session を特定できない可能性があります。"
          + "「削除して解除」でもアプリ内データは消さず、記録を残します。(\(inventoryLoadFailure))")
    }
    lines.append("repository と worktree のファイルには触れません。")
    return lines.joined(separator: "\n")
  }
}
