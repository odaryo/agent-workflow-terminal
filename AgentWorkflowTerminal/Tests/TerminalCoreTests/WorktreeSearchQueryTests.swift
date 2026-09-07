import Testing

@testable import TerminalCore

@Suite("§8.2 検索クエリ")
struct WorktreeSearchQueryTests {
  @Test(
    "空文字・空白のみは実行しないクエリとして表現できない",
    arguments: ["", " ", "   ", "\t", "\n", " \t \n "])
  func rejectsBlankTerms(term: String) {
    #expect(WorktreeSearchQuery(term: term, scope: .respectingGitignore) == nil)
  }

  @Test("前後の空白は検索語の一部として残る")
  func keepsSurroundingWhitespace() throws {
    let query = try #require(WorktreeSearchQuery(term: " foo ", scope: .respectingGitignore))
    #expect(query.term == " foo ")
  }

  @Test("既定は gitignore 尊重・正規表現 OFF・全文検索")
  func defaults() throws {
    let query = try #require(WorktreeSearchQuery(term: "foo", scope: .respectingGitignore))
    #expect(query.scope == .respectingGitignore)
    #expect(query.usesRegularExpression == false)
    #expect(query.target == .fullText)
  }

  @Test("ファイル名検索では正規表現の指定を持ち越さない")
  func fileNameSearchIgnoresRegularExpression() throws {
    let query = try #require(
      WorktreeSearchQuery(
        term: "foo", scope: .allFiles, usesRegularExpression: true, target: .fileName))
    #expect(query.usesRegularExpression == false)
  }
}

@Suite("§8.2 既定値")
struct WorktreeSearchLimitsTests {
  @Test("既定の全体上限が引数なしでも適用される")
  func appliesDefaultResultLimit() throws {
    let path = try #require(WorktreeRelativePath("a.txt"))
    let line = try #require(WorktreeSearchLine(text: "hello", matches: [], isTruncated: false))
    let matches = try (1...(WorktreeSearchLimits.maximumResultCount + 1)).map { number in
      try #require(WorktreeSearchMatch(path: path, lineNumber: number, line: line))
    }
    let outcome = WorktreeSearchOutcome.applyingResultLimit(
      to: matches, filesReachingPerFileLimit: [])
    #expect(outcome.matches.count == WorktreeSearchLimits.maximumResultCount)
    #expect(outcome.truncation.reachedResultLimit)
  }
}
