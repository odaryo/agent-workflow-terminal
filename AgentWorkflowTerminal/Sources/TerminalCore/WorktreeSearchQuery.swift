/// 設計書 §8.2 の既定値。設定可能な値であり、確定仕様 (§8.1) ではない。
public enum WorktreeSearchLimits {
  public static let maximumResultCount = 1_000
  public static let maximumMatchesPerFile = 100
  /// 1行の表示幅。ripgrep の `--max-columns` は `--json` 出力に効かない (実測 15.2.0) ため、
  /// 切り詰めは出力を読む側で行う。
  public static let maximumDisplayedColumns = 500
}

public enum WorktreeSearchScope: Sendable, Hashable, CaseIterable {
  /// ripgrep の既定動作。
  case respectingGitignore
  /// `--no-ignore --hidden`。ただし `.git/` は常に除く。
  case allFiles
}

public enum WorktreeSearchTarget: Sendable, Hashable, CaseIterable {
  case fullText
  case fileName
}

public struct WorktreeSearchQuery: Sendable, Hashable {
  public let term: String
  public let scope: WorktreeSearchScope
  public let usesRegularExpression: Bool
  public let target: WorktreeSearchTarget

  /// 空白のみの語は検索を実行しない。`term` 自体は trim しない — 前後の空白は
  /// 検索語の一部として意味を持ち、削ると別の語を検索したことになる。
  public init?(
    term: String,
    scope: WorktreeSearchScope,
    usesRegularExpression: Bool = false,
    target: WorktreeSearchTarget = .fullText
  ) {
    guard term.contains(where: { !$0.isWhitespace }) else { return nil }
    self.term = term
    self.scope = scope
    // ファイル名検索は §8.2 の既定で部分一致に固定した。指定を保持すると、UI で
    // 正規表現を ON にしたまま切り替えたときに「効いている」ように見える。
    self.usesRegularExpression = target == .fileName ? false : usesRegularExpression
    self.target = target
  }
}
