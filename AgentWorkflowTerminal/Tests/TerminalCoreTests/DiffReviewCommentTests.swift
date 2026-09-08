import Foundation
import Testing

@testable import TerminalCore

@Suite("§9.2 レビューコメントの保持と文面")
struct DiffReviewCommentTests {
  private static let snapshotID = DiffSnapshotID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1") ?? UUID())
  private static let laterSnapshotID = DiffSnapshotID(
    rawValue: UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000B2") ?? UUID())

  private static func file(path: String, texts: [String]) -> UnifiedDiffFile {
    UnifiedDiffFile(
      oldPath: path, newPath: path, changeKind: .modified,
      content: .hunks([
        UnifiedDiffHunk(
          oldStart: 1, oldCount: texts.count, newStart: 1, newCount: texts.count, section: "",
          lines: texts.enumerated().map { index, text in
            UnifiedDiffLine(
              kind: .context, oldLineNumber: index + 1, newLineNumber: index + 1, text: text)
          })
      ]))
  }

  private static func snapshot(
    id: DiffSnapshotID = snapshotID, paths: [String] = ["a.swift"],
    texts: [String] = ["one", "two"]
  ) -> DiffSnapshot {
    DiffSnapshot(
      id: id,
      subject: .commit(hash: "c0ffee"),
      createdAt: Date(timeIntervalSince1970: 0),
      sections: [
        DiffOriginSection(
          origin: .unstaged, files: paths.map { file(path: $0, texts: texts) }),
        DiffOriginSection(origin: .staged, files: paths.map { file(path: $0, texts: texts) }),
      ],
      observation: DiffSnapshotObservation(headObject: nil, files: []))
  }

  private static func comment(
    idSuffix: String,
    snapshot: DiffSnapshot,
    origin: DiffChangeOrigin = .unstaged,
    path: String = "a.swift",
    side: DiffLineSide = .new,
    lines: (Int, Int) = (1, 1),
    body: String = "本文",
    createdAt: TimeInterval = 0
  ) throws -> DiffReviewComment {
    let range = try #require(DiffLineRange(start: lines.0, end: lines.1))
    let anchor = try #require(
      snapshot.commentAnchor(origin: origin, path: path, side: side, lines: range))
    let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000\(idSuffix)"))
    return DiffReviewComment(
      id: DiffReviewCommentID(rawValue: id), anchor: anchor, body: body,
      createdAt: Date(timeIntervalSince1970: createdAt))
  }

  // MARK: - 保持

  @Test("追加・削除・列挙ができ、同じ ID は二重に持たない")
  func addsRemovesAndEnumerates() throws {
    let snapshot = Self.snapshot()
    var comments = DiffReviewComments()
    let first = try Self.comment(idSuffix: "0001", snapshot: snapshot)
    let added = comments.add(first)
    let addedTwice = comments.add(first)
    #expect(added)
    #expect(!addedTwice)
    #expect(comments.count == 1)
    let removed = comments.remove(first.id)
    let removedTwice = comments.remove(first.id)
    #expect(removed)
    #expect(!removedTwice)
    #expect(comments.isEmpty)
  }

  @Test("列挙順は挿入順に依らず決定的")
  func enumerationOrderIsDeterministic() throws {
    let snapshot = Self.snapshot(paths: ["b.swift", "a.swift"])
    let one = try Self.comment(
      idSuffix: "0001", snapshot: snapshot, path: "b.swift", lines: (1, 1))
    let two = try Self.comment(
      idSuffix: "0002", snapshot: snapshot, path: "a.swift", lines: (2, 2))
    let three = try Self.comment(
      idSuffix: "0003", snapshot: snapshot, path: "a.swift", lines: (1, 2))
    let four = try Self.comment(
      idSuffix: "0004", snapshot: snapshot, origin: .staged, path: "a.swift", lines: (1, 1))

    var forwards = DiffReviewComments()
    for comment in [one, two, three, four] { forwards.add(comment) }
    var backwards = DiffReviewComments()
    for comment in [four, three, two, one] { backwards.add(comment) }

    let expected = [four.id, three.id, two.id, one.id]
    #expect(forwards.all.map(\.id) == expected)
    #expect(backwards.all.map(\.id) == expected)
  }

  /// NFC の `é.swift` / NFD の `é.swift` / `f.swift`。UTF-8 の先頭バイトは 0xC3 / 0x65 / 0x66 で、
  /// バイト列順では NFD < f < NFC となり、`String` の `==` では NFC と NFD が等しくなる。
  /// 同値判定だけを `String` の `==` に戻すと、この3件で `a < b < c < a` の循環ができる。
  @Test("正準等価な別表記のパスがあっても順序に循環ができない")
  func orderIsAStrictWeakOrderingAcrossEquivalentPaths() throws {
    let nfc = "\u{00E9}.swift"
    let nfd = "e\u{0301}.swift"
    #expect(nfc == nfd)
    let snapshot = Self.snapshot(paths: [nfc, nfd, "f.swift"])
    let comments = try [
      Self.comment(idSuffix: "000A", snapshot: snapshot, path: nfc, body: "NFC への指摘"),
      Self.comment(idSuffix: "000B", snapshot: snapshot, path: nfd, body: "NFD への指摘"),
      Self.comment(idSuffix: "000C", snapshot: snapshot, path: "f.swift", body: "f への指摘"),
    ]

    for left in comments {
      for right in comments where left.id != right.id {
        // 非対称性: 両方向が真になる (= 同値なのに順序が付く) 組を作らせない。
        #expect(
          !(DiffReviewCommentOrder.precedes(left, right)
            && DiffReviewCommentOrder.precedes(right, left)))
      }
    }
    // 推移性: 循環があるとこの3つのうち少なくとも1つが破れる。
    for triple in [
      (comments[0], comments[1], comments[2]), (comments[1], comments[2], comments[0]),
      (comments[2], comments[0], comments[1]),
    ] {
      let (first, second, third) = triple
      if DiffReviewCommentOrder.precedes(first, second),
        DiffReviewCommentOrder.precedes(second, third)
      {
        #expect(DiffReviewCommentOrder.precedes(first, third))
      }
    }

    var orders: Set<String> = []
    for permutation in Self.permutations(of: comments) {
      var set = DiffReviewComments()
      for comment in permutation { set.add(comment) }
      orders.insert(set.all.map(\.body).joined(separator: "|"))
      // batch の文面も挿入順で変わらないこと (§9.2 の Review batch)。
      #expect(
        DiffReviewCommentMessage.batchText(for: permutation)
          == DiffReviewCommentMessage.batchText(for: comments))
    }
    #expect(orders.count == 1)
  }

  private static func permutations(
    of comments: [DiffReviewComment]
  ) -> [[DiffReviewComment]] {
    guard comments.count > 1 else { return [comments] }
    return comments.indices.flatMap { index -> [[DiffReviewComment]] in
      var rest = comments
      let picked = rest.remove(at: index)
      return permutations(of: rest).map { [picked] + $0 }
    }
  }

  @Test("正準等価な別表記のパスのコメントを混ぜて数えない")
  func filtersByPathBytes() throws {
    let nfc = "\u{00E9}.swift"
    let nfd = "e\u{0301}.swift"
    let snapshot = Self.snapshot(paths: [nfc, nfd])
    var comments = DiffReviewComments()
    let onNFC = try Self.comment(idSuffix: "000A", snapshot: snapshot, path: nfc)
    let onNFD = try Self.comment(idSuffix: "000B", snapshot: snapshot, path: nfd)
    for comment in [onNFC, onNFD] { comments.add(comment) }
    #expect(
      comments.comments(in: Self.snapshotID, origin: .unstaged, path: nfc).map(\.id) == [onNFC.id])
    #expect(
      comments.comments(in: Self.snapshotID, origin: .unstaged, path: nfd).map(\.id) == [onNFD.id])
  }

  @Test("snapshot・出所・パスで絞り込める")
  func filtersBySnapshotOriginAndPath() throws {
    let opened = Self.snapshot()
    let refreshed = Self.snapshot(id: Self.laterSnapshotID)
    var comments = DiffReviewComments()
    let unstaged = try Self.comment(idSuffix: "0001", snapshot: opened)
    let staged = try Self.comment(idSuffix: "0002", snapshot: opened, origin: .staged)
    let newer = try Self.comment(idSuffix: "0003", snapshot: refreshed)
    for comment in [unstaged, staged, newer] { comments.add(comment) }

    #expect(comments.comments(in: Self.snapshotID).map(\.id) == [staged.id, unstaged.id])
    #expect(
      comments.comments(in: Self.snapshotID, origin: .unstaged, path: "a.swift").map(\.id)
        == [unstaged.id])
    #expect(comments.comments(in: Self.laterSnapshotID).map(\.id) == [newer.id])
  }

  @Test("送信済みは時刻として区別でき、未送信は nil のまま")
  func marksSent() throws {
    let snapshot = Self.snapshot()
    var comments = DiffReviewComments()
    let comment = try Self.comment(idSuffix: "0001", snapshot: snapshot)
    comments.add(comment)
    #expect(comments.comment(comment.id)?.sentAt == nil)
    let marked = comments.markSent(comment.id, at: Date(timeIntervalSince1970: 100))
    #expect(marked)
    #expect(comments.comment(comment.id)?.sentAt == Date(timeIntervalSince1970: 100))
  }

  // MARK: - 文面

  @Test("単体送信の文面を固定する")
  func fixesSingleCommentText() throws {
    let snapshot = Self.snapshot()
    let comment = try Self.comment(
      idSuffix: "0001", snapshot: snapshot, lines: (1, 2), body: "ここを直して")
    #expect(
      DiffReviewCommentMessage.text(for: comment) == """
        [Diff review comment]
        file: a.swift
        origin: unstaged
        side: new
        lines: 1-2
        code:
        one
        two
        comment:
        ここを直して
        [end of comment]
        """)
  }

  @Test("単一行は行範囲を1つの番号で書く")
  func writesSingleLineRange() throws {
    let snapshot = Self.snapshot()
    let comment = try Self.comment(idSuffix: "0001", snapshot: snapshot, lines: (2, 2))
    #expect(DiffReviewCommentMessage.text(for: comment).contains("\nlines: 2\n"))
  }

  @Test("文面の末尾に改行を付けない (§9.2.1 制約1)", arguments: ["本文", "末尾に改行\n", ""])
  func neverEndsWithNewline(body: String) throws {
    let snapshot = Self.snapshot()
    let comment = try Self.comment(idSuffix: "0001", snapshot: snapshot, body: body)
    let single = DiffReviewCommentMessage.text(for: comment)
    #expect(single.last != "\n")
    #expect(DiffReviewCommentMessage.batchText(for: [comment]).last != "\n")
  }

  @Test("本文と元コードを加工しない (§9.2.1 制約2 は注入層の責務)")
  func keepsBodyAndCodeVerbatim() throws {
    let snapshot = Self.snapshot(texts: ["  let x = \"\\t\"", "two"])
    let body = "制御文字 \u{1B}[201~ と タブ\t を含む"
    let comment = try Self.comment(idSuffix: "0001", snapshot: snapshot, body: body)
    let text = DiffReviewCommentMessage.text(for: comment)
    #expect(text.contains(body))
    #expect(text.contains("  let x = \"\\t\""))
  }

  @Test("batch は引数の順に依らず決定的に並ぶ")
  func batchOrderIsDeterministic() throws {
    let snapshot = Self.snapshot(paths: ["b.swift", "a.swift"])
    let one = try Self.comment(
      idSuffix: "0001", snapshot: snapshot, path: "b.swift", body: "b の指摘")
    let two = try Self.comment(
      idSuffix: "0002", snapshot: snapshot, path: "a.swift", body: "a の指摘")
    #expect(
      DiffReviewCommentMessage.batchText(for: [one, two])
        == DiffReviewCommentMessage.batchText(for: [two, one]))
    let text = DiffReviewCommentMessage.batchText(for: [one, two])
    let aIndex = try #require(text.range(of: "a の指摘"))
    let bIndex = try #require(text.range(of: "b の指摘"))
    #expect(aIndex.lowerBound < bIndex.lowerBound)
    #expect(text.hasPrefix("[Diff review batch] 2 件\n"))
  }

  @Test("batch が空なら見出しだけを返す")
  func batchOfNoComments() {
    #expect(DiffReviewCommentMessage.batchText(for: []) == "[Diff review batch] 0 件")
  }
}
