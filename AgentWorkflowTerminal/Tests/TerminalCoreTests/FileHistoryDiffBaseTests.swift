import TerminalCore
import Testing

/// Commit Diff (§9.1.2) は merge の比較対象を推測しないが、ファイル履歴の Diff (§7.3) は
/// 第1親と比べ、そうしたことを表示側へ伝える。
@Suite("§7.3 ファイル履歴の Diff の比較対象")
struct FileHistoryDiffBaseTests {
  @Test("親が1つなら親と比べる")
  func comparesWithSingleParent() {
    #expect(FileHistoryDiffBase.base(parentIDs: ["abc"]) == .parent("abc"))
  }

  @Test("親を持たない commit は空 tree と比べる")
  func comparesRootCommitWithEmptyTree() {
    #expect(FileHistoryDiffBase.base(parentIDs: []) == .emptyTree)
  }

  @Test("merge commit は第1親と比べ、親の数を保持する")
  func comparesMergeWithFirstParent() {
    let base = FileHistoryDiffBase.base(parentIDs: ["abc", "def", "123"])
    #expect(base == .firstParentOfMerge("abc", parentCount: 3))
    #expect(base.comparedParentID == "abc")
    #expect(FileHistoryDiffBase.emptyTree.comparedParentID == nil)
  }
}
