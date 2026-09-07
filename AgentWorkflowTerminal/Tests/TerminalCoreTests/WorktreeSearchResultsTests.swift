import Testing

@testable import TerminalCore

private func line(
  _ text: String,
  matches: [Range<Int>] = [],
  isTruncated: Bool = false
) throws -> WorktreeSearchLine {
  let ranges = matches.map { range in
    let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
    let upper = text.index(text.startIndex, offsetBy: range.upperBound)
    return lower..<upper
  }
  return try #require(
    WorktreeSearchLine(text: text, matches: ranges, isTruncated: isTruncated))
}

private func match(
  _ path: String,
  _ lineNumber: Int,
  _ text: String = "hello"
) throws -> WorktreeSearchMatch {
  let relativePath = try #require(WorktreeRelativePath(path))
  let lineValue = try line(text)
  return try #require(
    WorktreeSearchMatch(path: relativePath, lineNumber: lineNumber, line: lineValue))
}

@Suite("§8 検索結果の値")
struct WorktreeSearchResultsTests {
  @Test("行テキストに LF は含められない")
  func rejectsNewlineInLineText() {
    #expect(WorktreeSearchLine(text: "a\nb", matches: [], isTruncated: false) == nil)
    #expect(WorktreeSearchLine(text: "a\r\nb", matches: [], isTruncated: false) == nil)
  }

  @Test("孤立した CR は行の中身として保つ")
  func keepsLoneCarriageReturn() {
    #expect(WorktreeSearchLine(text: "a\rb", matches: [], isTruncated: false) != nil)
  }

  @Test("マッチ範囲は行テキストの範囲内であること")
  func rejectsOutOfBoundsMatch() throws {
    let text = "hello"
    let other = "hello world"
    let range = other.startIndex..<other.index(other.startIndex, offsetBy: 11)
    #expect(WorktreeSearchLine(text: text, matches: [range], isTruncated: false) == nil)
  }

  @Test("行番号は 1 始まり")
  func rejectsNonPositiveLineNumber() throws {
    let path = try #require(WorktreeRelativePath("a.txt"))
    let text = try line("hello")
    #expect(WorktreeSearchMatch(path: path, lineNumber: 0, line: text) == nil)
    #expect(WorktreeSearchMatch(path: path, lineNumber: -1, line: text) == nil)
    #expect(WorktreeSearchMatch(path: path, lineNumber: 1, line: text) != nil)
  }

  @Test("マッチ範囲は行テキスト上の位置として読める")
  func matchRangeIsPositionInLineText() throws {
    let text = "マルチバイト hello テスト"
    let result = try line(text, matches: [7..<12])
    let range = try #require(result.matches.first)
    #expect(String(text[range]) == "hello")
  }

  @Test("全文検索の結果は行番号つきの開く対象になる")
  func openTargetOfFullTextMatch() throws {
    let target = try match("sub/b.txt", 12).openTarget
    #expect(target.path.value == "sub/b.txt")
    #expect(target.lineNumber == 12)
  }

  @Test("ファイル名検索の結果は行を持たない")
  func openTargetOfFileNameMatch() throws {
    let path = try #require(WorktreeRelativePath("sub/b.txt"))
    let matches = WorktreeFileNameSearch.matches(term: "B.TX", in: [path])
    let first = try #require(matches.first)
    #expect(first.openTarget.path.value == "sub/b.txt")
    #expect(first.openTarget.lineNumber == nil)
  }
}

@Suite("§8.2 打ち切り")
struct WorktreeSearchTruncationTests {
  @Test("全体上限を超えたら件数を切り、切ったことを結果から読める")
  func appliesResultLimit() throws {
    let matches = try (1...5).map { try match("a.txt", $0) }
    let outcome = WorktreeSearchOutcome.applyingResultLimit(
      to: matches, filesReachingPerFileLimit: [], limit: 3)
    #expect(outcome.matches.count == 3)
    #expect(outcome.matches.map(\.lineNumber) == [1, 2, 3])
    #expect(outcome.truncation.reachedResultLimit)
    #expect(outcome.truncation.isTruncated)
  }

  @Test("上限ちょうどは打ち切りではない")
  func exactLimitIsNotTruncated() throws {
    let matches = try (1...3).map { try match("a.txt", $0) }
    let outcome = WorktreeSearchOutcome.applyingResultLimit(
      to: matches, filesReachingPerFileLimit: [], limit: 3)
    #expect(outcome.matches.count == 3)
    #expect(outcome.truncation.reachedResultLimit == false)
    #expect(outcome.truncation.isTruncated == false)
  }

  @Test("ファイル単位の打ち切りは全体上限とは別に読める")
  func perFileLimitIsDistinctFromResultLimit() throws {
    let many = try #require(WorktreeRelativePath("many.txt"))
    let manyMatch = try match("many.txt", 1)
    let outcome = WorktreeSearchOutcome.applyingResultLimit(
      to: [manyMatch], filesReachingPerFileLimit: [many], limit: 1_000)
    #expect(outcome.truncation.reachedResultLimit == false)
    #expect(outcome.truncation.filesReachingPerFileLimit == [many])
    #expect(outcome.truncation.isTruncated)
  }

  @Test("全体上限で表示から外れたファイルの、ファイル単位の打ち切りは報告しない")
  func dropsPerFileLimitForFilesNotShown() throws {
    let shown = try #require(WorktreeRelativePath("a.txt"))
    let dropped = try #require(WorktreeRelativePath("z.txt"))
    let shownMatch = try match("a.txt", 1)
    let droppedMatch = try match("z.txt", 1)
    let outcome = WorktreeSearchOutcome.applyingResultLimit(
      to: [shownMatch, droppedMatch],
      filesReachingPerFileLimit: [shown, dropped],
      limit: 1)
    #expect(outcome.truncation.reachedResultLimit)
    #expect(outcome.truncation.filesReachingPerFileLimit == [shown])
  }

  @Test("0 件は打ち切りではない")
  func emptyIsNotTruncated() {
    let outcome = WorktreeSearchOutcome.applyingResultLimit(
      to: [], filesReachingPerFileLimit: [], limit: 1_000)
    #expect(outcome.matches.isEmpty)
    #expect(outcome.truncation.isTruncated == false)
  }
}

@Suite("§8.2 ファイル名検索")
struct WorktreeFileNameSearchTests {
  private func paths(_ values: [String]) throws -> [WorktreeRelativePath] {
    try values.map { try #require(WorktreeRelativePath($0)) }
  }

  @Test("大文字小文字を無視した部分一致")
  func caseInsensitiveSubstring() throws {
    let candidates = try paths(["Sources/Foo.swift", "Tests/bar.swift", "README.md"])
    let matched = WorktreeFileNameSearch.matches(term: "foo", in: candidates)
    #expect(matched.map(\.path.value) == ["Sources/Foo.swift"])
  }

  @Test("相対パス全体が一致対象")
  func matchesAgainstWholeRelativePath() throws {
    let candidates = try paths(["Sources/Foo.swift", "Tests/Bar.swift"])
    let matched = WorktreeFileNameSearch.matches(term: "tests/", in: candidates)
    #expect(matched.map(\.path.value) == ["Tests/Bar.swift"])
  }

  @Test("一致範囲は相対パス上の位置")
  func matchRangeIsPositionInPath() throws {
    let candidates = try paths(["Sources/Foo.swift"])
    let matched = WorktreeFileNameSearch.matches(term: "foo", in: candidates)
    let first = try #require(matched.first)
    #expect(String(first.path.value[first.range]) == "Foo")
  }

  @Test("空白のみの語では何も返さない")
  func blankTermMatchesNothing() throws {
    let candidates = try paths(["Sources/Foo.swift"])
    #expect(WorktreeFileNameSearch.matches(term: "  ", in: candidates).isEmpty)
    #expect(WorktreeFileNameSearch.matches(term: "", in: candidates).isEmpty)
  }

  @Test("入力の順序を保つ")
  func preservesInputOrder() throws {
    let candidates = try paths(["b/x.swift", "a/x.swift"])
    let matched = WorktreeFileNameSearch.matches(term: "x.swift", in: candidates)
    #expect(matched.map(\.path.value) == ["b/x.swift", "a/x.swift"])
  }
}

@Suite("§8.1 検索範囲は worktree の中だけ")
struct WorktreePathScopeTests {
  @Test("root 配下の絶対パスは相対パスになる")
  func relativizesUnderRoot() throws {
    let path = WorktreePathScope.relativePath(
      forAbsolutePath: "/tmp/wt/sub/b.txt", underRoot: "/tmp/wt")
    #expect(path?.value == "sub/b.txt")
  }

  @Test("root の末尾スラッシュは結果を変えない")
  func toleratesTrailingSlashOnRoot() throws {
    let path = WorktreePathScope.relativePath(
      forAbsolutePath: "/tmp/wt/a.txt", underRoot: "/tmp/wt/")
    #expect(path?.value == "a.txt")
  }

  @Test(
    "root の外を指すパスは捨てる",
    arguments: [
      "/tmp/other/a.txt",
      "/tmp/wtx/a.txt",
      "/tmp/wt/../other/a.txt",
      "/tmp",
      "/tmp/wt",
      "/tmp/wt/",
      "relative/a.txt",
      "",
    ])
  func rejectsOutsideRoot(absolute: String) {
    #expect(
      WorktreePathScope.relativePath(forAbsolutePath: absolute, underRoot: "/tmp/wt") == nil)
  }

  @Test("root が絶対パスでなければ何も通さない")
  func rejectsRelativeRoot() {
    #expect(
      WorktreePathScope.relativePath(forAbsolutePath: "/tmp/wt/a.txt", underRoot: "wt") == nil)
  }

  @Test("NFD で届いたパスも root の下だと判定できる")
  func matchesAcrossUnicodeNormalization() throws {
    let root = "/tmp/\u{304B}\u{3099}"
    let absolute = "/tmp/\u{304C}/a.txt"
    let path = WorktreePathScope.relativePath(forAbsolutePath: absolute, underRoot: root)
    #expect(path?.value == "a.txt")
  }
}
