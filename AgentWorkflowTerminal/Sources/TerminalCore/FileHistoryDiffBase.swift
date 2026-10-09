/// ファイル履歴の各 commit が「そのファイルに入れた変更」の比較対象 (設計書 §7.3)。
///
/// Commit Diff (§9.1.2、`CommitDiffRange`) と違い merge commit を拒否しない。ファイル履歴は
/// `git log --diff-merges=first-parent` で merge を第1親との差分として列挙するので、Diff も
/// 同じ比較対象にそろえる。どの親と比べたかは表示側が示す。
public enum FileHistoryDiffBase: Sendable, Equatable {
  case emptyTree
  case parent(String)
  case firstParentOfMerge(String, parentCount: Int)

  /// `parentIDs` は `%P` の順序 (第1親が先頭) をそのまま渡す。
  public static func base(parentIDs: [String]) -> Self {
    guard let first = parentIDs.first else { return .emptyTree }
    return parentIDs.count == 1
      ? .parent(first) : .firstParentOfMerge(first, parentCount: parentIDs.count)
  }

  public var comparedParentID: String? {
    switch self {
    case .emptyTree: nil
    case .parent(let id), .firstParentOfMerge(let id, _): id
    }
  }
}
