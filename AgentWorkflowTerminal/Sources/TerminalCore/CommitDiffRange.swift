public enum CommitDiffComparison: Sendable, Equatable {
  case parent(String)
  /// 親を持たない commit。比較対象は空 tree になる。
  case rootCommit
  /// どの親と比べるかを設計書が定めていないため未対応 (§9.1.2)。第一親を推測で選ばない。
  case unsupportedMergeCommit(parents: [String])
}

public enum CommitDiffRange {
  /// `parentHashes` は `git log` の `%P` の順序をそのまま渡す。
  public static func comparison(parentHashes: [String]) -> CommitDiffComparison {
    switch parentHashes.count {
    case 0: .rootCommit
    case 1: .parent(parentHashes[0])
    default: .unsupportedMergeCommit(parents: parentHashes)
    }
  }
}
