import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§9.3 別 snapshot の未送信コメント通知")
struct DiffUnsentCommentSummaryTests {
  @Test("表示中の snapshot は通知対象から除き、元の snapshot の件数は保持する")
  func excludesCurrentSnapshot() throws {
    let old = snapshot()
    let current = snapshot()
    let comments = try comments([(old, false), (current, false), (current, false)])
    let summary = summary([old, current], comments: comments, current: current)

    #expect(summary.count(in: current.id) == 2)
    #expect(summary.otherSnapshotCount == 1)
    #expect(summary.otherCommentCount == 1)
    #expect(summary.nextOtherSnapshot?.id == old.id)
    #expect(summary.hasOtherUnsentComments)
  }

  @Test("送信済みは数えず、snapshot ごとに未送信だけを数える")
  func excludesSentComments() throws {
    let old = snapshot()
    let current = snapshot()
    let comments = try comments([(old, true), (old, false), (current, true)])
    let summary = summary([old, current], comments: comments, current: current)

    #expect(summary.count(in: old.id) == 1)
    #expect(summary.count(in: current.id) == 0)
    #expect(summary.otherCommentCount == 1)
  }

  @Test("複数 snapshot の合計を数え、履歴への追加順が最新の未送信 snapshot を開く")
  func totalsMultipleSnapshots() throws {
    let first = snapshot()
    let second = snapshot()
    let sentOnly = snapshot()
    let current = snapshot()
    let entries: [(DiffSnapshot, Bool)] = [
      (second, false), (first, false), (second, false), (first, false), (first, false),
      (sentOnly, true), (current, false),
    ]
    let summary = summary(
      [first, second, sentOnly, current], comments: try comments(entries), current: current)

    #expect(summary.otherSnapshotCount == 2)
    #expect(summary.otherCommentCount == 5)
    #expect(summary.nextOtherSnapshot?.id == second.id)
    #expect(summary.count(in: first.id) == 3)
    #expect(summary.count(in: second.id) == 2)
    #expect(summary.count(in: sentOnly.id) == 0)
  }

  @Test("過去の snapshot を表示していても、それ以降の未送信 snapshot に戻れる")
  func findsNewerSnapshot() throws {
    let old = snapshot()
    let latest = snapshot()
    let summary = summary(
      [old, latest], comments: try comments([(old, false), (latest, false)]), current: old)

    #expect(summary.nextOtherSnapshot?.id == latest.id)
    #expect(summary.otherCommentCount == 1)
  }

  @Test("未送信のある snapshot が3つあっても、バナーを辿ると新しい順に最古まで届き最新へ戻る")
  func cyclesThroughAllUnsentSnapshots() throws {
    let oldest = snapshot()
    let middle = snapshot()
    let newest = snapshot()
    let comments = try comments([(oldest, false), (middle, false), (newest, false)])

    #expect(
      summary([oldest, middle, newest], comments: comments, current: newest).nextOtherSnapshot?.id
        == middle.id)
    #expect(
      summary([oldest, middle, newest], comments: comments, current: middle).nextOtherSnapshot?.id
        == oldest.id)
    #expect(
      summary([oldest, middle, newest], comments: comments, current: oldest).nextOtherSnapshot?.id
        == newest.id)
  }

  @Test("別 snapshot に未送信が無ければバナーを出さない", arguments: [false, true])
  func hidesBannerWithoutOtherUnsentComments(hasSentComment: Bool) throws {
    let old = snapshot()
    let current = snapshot()
    var entries: [(DiffSnapshot, Bool)] = [(current, false)]
    if hasSentComment { entries.append((old, true)) }
    let summary = summary([old, current], comments: try comments(entries), current: current)

    #expect(!summary.hasOtherUnsentComments)
    #expect(summary.nextOtherSnapshot == nil)
    #expect(summary.otherCommentCount == 0)
    #expect(summary.otherSnapshotCount == 0)
  }

  @Test("履歴もコメントも無ければ通知しない")
  func emptyHistory() {
    let summary = DiffUnsentCommentSummary(
      history: DiffSnapshotHistory(), comments: DiffReviewComments(), currentSnapshotID: nil)
    #expect(!summary.hasOtherUnsentComments)
    #expect(summary.nextOtherSnapshot == nil)
  }

  private func summary(
    _ snapshots: [DiffSnapshot], comments: DiffReviewComments, current: DiffSnapshot
  ) -> DiffUnsentCommentSummary {
    var history = DiffSnapshotHistory()
    for snapshot in snapshots { history.append(snapshot) }
    return DiffUnsentCommentSummary(
      history: history, comments: comments, currentSnapshotID: current.id)
  }

  private func snapshot() -> DiffSnapshot {
    DiffSnapshot(
      id: DiffSnapshotID(rawValue: UUID()), subject: .commit(hash: "abc"),
      createdAt: Date(timeIntervalSince1970: 0),
      sections: [
        DiffOriginSection(
          origin: .untracked,
          files: [UntrackedFileDiff.addedFile(path: "file.swift", content: "line\n")])
      ],
      observation: DiffSnapshotObservation(headObject: nil, files: []))
  }

  private func comments(_ entries: [(DiffSnapshot, Bool)]) throws -> DiffReviewComments {
    var comments = DiffReviewComments()
    for (snapshot, sent) in entries {
      let lines = try #require(DiffLineRange(line: 1))
      let anchor = try #require(
        snapshot.commentAnchor(origin: .untracked, path: "file.swift", side: .new, lines: lines))
      var comment = DiffReviewComment(
        id: DiffReviewCommentID(rawValue: UUID()), anchor: anchor, body: "review",
        createdAt: Date(timeIntervalSince1970: 0))
      if sent { comment.markSent(at: Date(timeIntervalSince1970: 1)) }
      comments.add(comment)
    }
    return comments
  }
}
