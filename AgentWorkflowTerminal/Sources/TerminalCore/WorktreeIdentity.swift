import Foundation

/// 値は worktree の管理ディレクトリの絶対パス (設計書 §3.5)。通常の worktree では
/// `<git common dir>/worktrees/<name>`、Project Root では `<git common dir>` そのもの。
///
/// 作業ツリーのパスや branch 名を識別子にしないのは、branch が worktree 内で切り替わり、
/// 作業ツリーのパスが `git worktree move` で変わる一方、管理ディレクトリ名はどちらの操作でも
/// 不変であるため (隔離リポジトリでの実測に基づく)。
///
/// - Important: 呼び出し側は `git rev-parse --absolute-git-dir` の出力をそのまま渡す。
///   この型は与えられた文字列を正規化しない (末尾 `/` の除去も `//` の畳み込みもしない)。
///   アプリ独自の正規化を挟むと、同じ worktree に対して git が返す決定的な文字列とは
///   一致しない ID を作り得るため。表記が違えば別の ID になる。
public struct WorktreeIdentity: Sendable, Hashable, Codable {
  public let rawValue: String

  /// 検証するのは絶対パス (`/` 始まり) であることだけで、実在するか、git の管理下かは見ない。
  /// ドメイン層はファイルシステムに触れないため (docs/coding-guidelines.md §2.1)。
  public init?(rawValue: String) {
    guard rawValue.hasPrefix("/") else { return nil }
    self.rawValue = rawValue
  }
}

extension WorktreeIdentity {
  /// 合成した鍵ではなくパス文字列そのものとして符号化する。永続化した値を人が読め、
  /// 復号側も `init?(rawValue:)` と同じ検証を通せるようにするため。
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let decoded = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "worktreeの安定IDは絶対パスでなければならない: \(rawValue)"
      )
    }
    self = decoded
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
