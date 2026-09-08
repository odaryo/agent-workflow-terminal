/// 実装 Agent pane へ貼り付ける文面の組み立て (設計書 §9.2)。
///
/// - Important: **末尾に改行を付けない。** §9.2.1 制約1 のとおり、受け側 pane が bracketed paste を
///   立てていなければ tmux は本文の LF を CR (= Enter) にして届けるため、末尾の改行は
///   「貼った直後に実行される」に直結する。本文が改行で終わっていても後ろへ足さないよう、
///   組み立ての最後の要素は常に固定の終端行にしてある。
/// - Important: **本文と元コードを加工しない。** 制御文字の検出と拒否は注入層
///   (`TmuxTextInjection`) の責務で、ここで sanitize・escape・置換を行うと「加工せず拒否」という
///   設計方針 (§9.2.1 制約2) が崩れる。したがって**この文面の区切りは曖昧である**: 本文中の
///   `[end of comment]` と終端行、元コード中の `comment:` と本文の見出し、元コードや本文中の
///   `code:` と元コードの見出しは、いずれも受け手から区別できない。とくに `comment:` / `code:`
///   は YAML・JSON・辞書リテラルに普通に現れるため、終端行の衝突よりずっと起こりやすい。
///   曖昧さを消すには本文か元コードを加工するしかないので、曖昧さの側を受け入れている。
public enum DiffReviewCommentMessage {
  private static let endMarker = "[end of comment]"

  public static func text(for comment: DiffReviewComment) -> String {
    let anchor = comment.anchor
    return
      ([
        "[Diff review comment]",
        "file: \(anchor.path)",
        "origin: \(token(anchor.origin))",
        "side: \(token(anchor.side))",
        "lines: \(lineLabel(anchor.lines))",
        "code:",
        anchor.anchoredText,
        "comment:",
        comment.body,
        endMarker,
      ] as [String]).joined(separator: "\n")
  }

  /// 引数の順序に依らず `DiffReviewCommentOrder` の並びで出す。呼び出し側の集め方で文面が
  /// 変わらないようにするため (§9.2 の「Review batch」)。
  public static func batchText(for comments: [DiffReviewComment]) -> String {
    let sorted = comments.sorted(by: DiffReviewCommentOrder.precedes)
    let header = "[Diff review batch] \(sorted.count) 件"
    guard !sorted.isEmpty else { return header }
    return ([header] + sorted.map(text(for:))).joined(separator: "\n\n")
  }

  private static func lineLabel(_ lines: DiffLineRange) -> String {
    lines.start == lines.end ? "\(lines.start)" : "\(lines.start)-\(lines.end)"
  }

  /// §9.1.3 の5区分。表示名ではなく安定した識別子を送る (`AgentAdapterID` と同じ理由)。
  /// 競合(unmerged)の分岐が通らないのは、`DiffSnapshot.commentAnchor` が出所として競合を
  /// 弾くため (§9.2)。`DiffCommentAnchor` の生成経路はそこだけなので、網羅性のためだけに残す。
  private static func token(_ origin: DiffChangeOrigin) -> String {
    switch origin {
    case .committed: "committed"
    case .staged: "staged"
    case .unstaged: "unstaged"
    case .untracked: "untracked"
    case .unmerged: "unmerged"
    }
  }

  private static func token(_ side: DiffLineSide) -> String {
    switch side {
    case .old: "old"
    case .new: "new"
    }
  }
}
