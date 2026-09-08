import Foundation
import Testing

@testable import TerminalCore

@Suite("§9.2 コメント anchor")
struct DiffCommentAnchorTests {
  private static let snapshotID = DiffSnapshotID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID())
  private static let otherSnapshotID = DiffSnapshotID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2") ?? UUID())

  private static func snapshot(
    id: DiffSnapshotID = snapshotID,
    sections: [DiffOriginSection]
  ) -> DiffSnapshot {
    DiffSnapshot(
      id: id,
      subject: .commit(hash: "c0ffee"),
      createdAt: Date(timeIntervalSince1970: 0),
      sections: sections,
      observation: DiffSnapshotObservation(headObject: nil, files: []))
  }

  /// old 1..3 / new 1..3。2行目だけが書き換えられている。
  private static func modifiedFile(path: String) -> UnifiedDiffFile {
    UnifiedDiffFile(
      oldPath: path,
      newPath: path,
      changeKind: .modified,
      content: .hunks([
        UnifiedDiffHunk(
          oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, section: "",
          lines: [
            UnifiedDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "alpha"),
            UnifiedDiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "old-two"),
            UnifiedDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "new-two"),
            UnifiedDiffLine(kind: .context, oldLineNumber: 3, newLineNumber: 3, text: "gamma"),
          ])
      ]))
  }

  private static func standardSnapshot() -> DiffSnapshot {
    snapshot(sections: [
      DiffOriginSection(origin: .unstaged, files: [modifiedFile(path: "a.swift")]),
      DiffOriginSection(origin: .staged, files: [modifiedFile(path: "a.swift")]),
    ])
  }

  // MARK: - 行範囲

  @Test("空の範囲と逆転した範囲は作れない", arguments: [(0, 0), (0, 3), (3, 2), (-1, 1)])
  func rejectsEmptyOrReversedRange(start: Int, end: Int) {
    #expect(DiffLineRange(start: start, end: end) == nil)
  }

  @Test("単一行は1行の範囲として表す")
  func singleLineIsARangeOfOne() throws {
    let range = try #require(DiffLineRange(line: 7))
    #expect(range.start == 7)
    #expect(range.end == 7)
    #expect(range.count == 1)
  }

  // MARK: - 生成

  @Test("snapshot に実在する行からだけ anchor を作れる")
  func buildsAnchorOnlyFromExistingLines() throws {
    let snapshot = Self.standardSnapshot()
    let range = try #require(DiffLineRange(start: 1, end: 3))
    #expect(
      snapshot.commentAnchor(origin: .unstaged, path: "a.swift", side: .new, lines: range) != nil)
    #expect(
      snapshot.commentAnchor(origin: .committed, path: "a.swift", side: .new, lines: range) == nil)
    #expect(
      snapshot.commentAnchor(origin: .unstaged, path: "missing", side: .new, lines: range) == nil)
    let outOfRange = try #require(DiffLineRange(start: 3, end: 4))
    #expect(
      snapshot.commentAnchor(origin: .unstaged, path: "a.swift", side: .new, lines: outOfRange)
        == nil)
  }

  /// §9.2「競合(unmerged)はコメント送信の対象外」。行を持つファイルを `.unmerged` 区分へ
  /// 入れても anchor は作れない — 出所そのもので弾いていることの証拠 (Issue #242)。
  /// `.conflicted` が本文を持たないという生成側の事情に頼ると、P3 で combined diff の本文を
  /// 出した時点で送信が黙って解禁される。
  @Test("行を持っていても競合(unmerged)からは anchor を作れない")
  func doesNotBuildAnchorForUnmerged() throws {
    let snapshot = Self.snapshot(sections: [
      DiffOriginSection(origin: .unmerged, files: [Self.modifiedFile(path: "a.swift")])
    ])
    let range = try #require(DiffLineRange(start: 1, end: 3))
    #expect(snapshot.file(origin: .unmerged, path: "a.swift")?.hunks.isEmpty == false)
    #expect(
      snapshot.commentAnchor(origin: .unmerged, path: "a.swift", side: .new, lines: range) == nil)
    #expect(
      snapshot.commentAnchor(origin: .unmerged, path: "a.swift", side: .old, lines: range) == nil)
  }

  @Test("側ごとに存在する行だけを見る")
  func resolvesLinesPerSide() throws {
    let snapshot = Self.standardSnapshot()
    let range = try #require(DiffLineRange(line: 2))
    let old = try #require(
      snapshot.commentAnchor(origin: .unstaged, path: "a.swift", side: .old, lines: range))
    let new = try #require(
      snapshot.commentAnchor(origin: .unstaged, path: "a.swift", side: .new, lines: range))
    #expect(old.anchoredLines.map(\.text) == ["old-two"])
    #expect(new.anchoredLines.map(\.text) == ["new-two"])
    #expect(old.textHash != new.textHash)
  }

  @Test("6要素をすべて保持する")
  func keepsAllSixElements() throws {
    let snapshot = Self.standardSnapshot()
    let range = try #require(DiffLineRange(start: 1, end: 3))
    let anchor = try #require(
      snapshot.commentAnchor(origin: .staged, path: "a.swift", side: .new, lines: range))
    #expect(anchor.snapshotID == Self.snapshotID)
    #expect(anchor.origin == .staged)
    #expect(anchor.path == "a.swift")
    #expect(anchor.side == .new)
    #expect(anchor.lines == range)
    #expect(anchor.anchoredLines.map(\.text) == ["alpha", "new-two", "gamma"])
    #expect(!anchor.textHash.isEmpty)
  }

  @Test("同じパス・側・行範囲でも出所が違えば別の anchor になる")
  func distinguishesOrigins() throws {
    let staged = Self.modifiedFile(path: "a.swift")
    let unstaged = UnifiedDiffFile(
      oldPath: "a.swift", newPath: "a.swift", changeKind: .modified,
      content: .hunks([
        UnifiedDiffHunk(
          oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "",
          lines: [
            UnifiedDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "unstaged")
          ])
      ]))
    let snapshot = Self.snapshot(sections: [
      DiffOriginSection(origin: .staged, files: [staged]),
      DiffOriginSection(origin: .unstaged, files: [unstaged]),
    ])
    let range = try #require(DiffLineRange(line: 1))
    let stagedAnchor = try #require(
      snapshot.commentAnchor(origin: .staged, path: "a.swift", side: .new, lines: range))
    let unstagedAnchor = try #require(
      snapshot.commentAnchor(origin: .unstaged, path: "a.swift", side: .new, lines: range))
    #expect(stagedAnchor.anchoredLines.map(\.text) == ["alpha"])
    #expect(unstagedAnchor.anchoredLines.map(\.text) == ["unstaged"])
    #expect(stagedAnchor != unstagedAnchor)
  }

  /// NFC の `é.swift` と NFD の `é.swift`。`String` の `==` は両者を等しいと答える。
  private static let nfcPath = "\u{00E9}.swift"
  private static let nfdPath = "e\u{0301}.swift"

  private static func singleLineFile(path: String, text: String) -> UnifiedDiffFile {
    UnifiedDiffFile(
      oldPath: path, newPath: path, changeKind: .modified,
      content: .hunks([
        UnifiedDiffHunk(
          oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "",
          lines: [
            UnifiedDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: text)
          ])
      ]))
  }

  @Test("正準等価な別表記のパスで別ファイルの行を掴まない")
  func doesNotConfuseCanonicallyEquivalentPaths() throws {
    #expect(Self.nfcPath == Self.nfdPath)  // `String` の比較ではこの2つは区別できない
    let snapshot = Self.snapshot(sections: [
      DiffOriginSection(
        origin: .committed,
        files: [
          Self.singleLineFile(path: Self.nfcPath, text: "NFC-line"),
          Self.singleLineFile(path: Self.nfdPath, text: "NFD-line"),
        ])
    ])
    let line = try #require(DiffLineRange(line: 1))
    let nfc = try #require(
      snapshot.commentAnchor(origin: .committed, path: Self.nfcPath, side: .new, lines: line))
    let nfd = try #require(
      snapshot.commentAnchor(origin: .committed, path: Self.nfdPath, side: .new, lines: line))
    // anchor が載せるパスと元コードが同じファイルのものであること。ここが割れると、
    // Agent へ送る文面が「このパス」と言いながら別ファイルの行を載せる。
    #expect(nfc.anchoredLines.map(\.text) == ["NFC-line"])
    #expect(nfd.anchoredLines.map(\.text) == ["NFD-line"])
    #expect(nfc.textHash != nfd.textHash)
    #expect(snapshot.verify(nfc) == .intact)
    #expect(snapshot.verify(nfd) == .intact)
  }

  // MARK: - ハッシュの前像

  @Test("ハッシュの前像は長さ前置の連結で固定する")
  func fixesHashPreimage() {
    let lines = [
      DiffAnchoredLine(lineNumber: 4, text: "let x = 1", isMissingTrailingNewline: false),
      DiffAnchoredLine(lineNumber: 5, text: "", isMissingTrailingNewline: true),
    ]
    #expect(
      DiffCommentAnchor.hashPreimage(of: lines)
        == "awt-diff-line-hash-v1:9:let x = 1:0:0::1")
    // `printf '%s' '<前像>' | shasum -a 256` で得た値。実装を通さずに固定する。
    #expect(
      DiffCommentAnchor.textHash(of: lines)
        == "8cfa2760b156c1ffd7fd337fa40a90ef9931921ac3fc1f6ac14a97314db29290")
  }

  @Test("末尾改行の有無でハッシュが変わる")
  func trailingNewlineFlagChangesHash() {
    let withFlag = [
      DiffAnchoredLine(lineNumber: 1, text: "same", isMissingTrailingNewline: true)
    ]
    let withoutFlag = [
      DiffAnchoredLine(lineNumber: 1, text: "same", isMissingTrailingNewline: false)
    ]
    #expect(DiffCommentAnchor.textHash(of: withFlag) != DiffCommentAnchor.textHash(of: withoutFlag))
  }

  @Test("行の区切りは長さ前置なので、境界をまたぐ書き換えを見分けられる")
  func lengthPrefixSeparatesLines() {
    let split = [
      DiffAnchoredLine(lineNumber: 1, text: "ab", isMissingTrailingNewline: false),
      DiffAnchoredLine(lineNumber: 2, text: "c", isMissingTrailingNewline: false),
    ]
    let merged = [
      DiffAnchoredLine(lineNumber: 1, text: "a", isMissingTrailingNewline: false),
      DiffAnchoredLine(lineNumber: 2, text: "bc", isMissingTrailingNewline: false),
    ]
    #expect(DiffCommentAnchor.textHash(of: split) != DiffCommentAnchor.textHash(of: merged))
  }

  // MARK: - 検証

  @Test("同じ snapshot の同じ行なら intact")
  func verifiesIntactAnchor() throws {
    let snapshot = Self.standardSnapshot()
    let range = try #require(DiffLineRange(start: 1, end: 3))
    let anchor = try #require(
      snapshot.commentAnchor(origin: .unstaged, path: "a.swift", side: .new, lines: range))
    #expect(snapshot.verify(anchor) == .intact)
  }

  @Test("別 snapshot に対する検証を「壊れている」へ丸めない (§9.3)")
  func doesNotRoundDifferentSnapshotToCorrupted() throws {
    let opened = Self.standardSnapshot()
    let range = try #require(DiffLineRange(line: 1))
    let anchor = try #require(
      opened.commentAnchor(origin: .unstaged, path: "a.swift", side: .new, lines: range))
    let refreshed = Self.snapshot(
      id: Self.otherSnapshotID,
      sections: [DiffOriginSection(origin: .unstaged, files: [Self.modifiedFile(path: "a.swift")])])
    #expect(
      refreshed.verify(anchor)
        == .differentSnapshot(anchor: Self.snapshotID, snapshot: Self.otherSnapshotID))
  }

  @Test("行が消えた場合とテキストが変わった場合を区別する")
  func distinguishesCorruptionReasons() throws {
    let snapshot = Self.standardSnapshot()
    let range = try #require(DiffLineRange(line: 1))
    let anchor = try #require(
      snapshot.commentAnchor(origin: .unstaged, path: "a.swift", side: .new, lines: range))

    let emptied = Self.snapshot(sections: [DiffOriginSection(origin: .unstaged, files: [])])
    #expect(emptied.verify(anchor) == .corrupted(.linesNotFound))

    let rewritten = Self.snapshot(sections: [
      DiffOriginSection(
        origin: .unstaged,
        files: [
          UnifiedDiffFile(
            oldPath: "a.swift", newPath: "a.swift", changeKind: .modified,
            content: .hunks([
              UnifiedDiffHunk(
                oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "",
                lines: [
                  UnifiedDiffLine(
                    kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "rewritten")
                ])
            ]))
        ])
    ])
    #expect(rewritten.verify(anchor) == .corrupted(.textHashMismatch))
  }
}
