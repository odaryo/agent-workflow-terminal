import Testing

@testable import TerminalCore

@Suite("§9.1.2 Commit Diff の比較対象")
struct CommitDiffRangeTests {
  @Test("親が1つなら親と比べる")
  func comparesWithSingleParent() {
    #expect(CommitDiffRange.comparison(parentHashes: ["abc"]) == .parent("abc"))
  }

  @Test("親を持たない commit は空 tree と比べる")
  func comparesRootCommitWithEmptyTree() {
    #expect(CommitDiffRange.comparison(parentHashes: []) == .rootCommit)
  }

  @Test("親が複数ある commit は第一親を推測せず未対応として返す")
  func doesNotGuessFirstParent() {
    #expect(
      CommitDiffRange.comparison(parentHashes: ["abc", "def"])
        == .unsupportedMergeCommit(parents: ["abc", "def"]))
  }
}
