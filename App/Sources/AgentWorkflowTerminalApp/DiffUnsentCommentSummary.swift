import TerminalCore

struct DiffUnsentCommentSummary {
  private let counts: [DiffSnapshotID: Int]
  let otherSnapshotCount: Int
  let otherCommentCount: Int
  /// バナーのリンクで開く snapshot。表示中より古い側の最新を先に出し、最古の次は最新へ戻る。
  /// 「他の中で最新」だけだと、未送信のある snapshot が3つ以上のとき最古へ辿れない。
  let nextOtherSnapshot: DiffSnapshot?

  var hasOtherUnsentComments: Bool { nextOtherSnapshot != nil }

  init(
    history: DiffSnapshotHistory, comments: DiffReviewComments,
    currentSnapshotID: DiffSnapshotID?
  ) {
    var counts: [DiffSnapshotID: Int] = [:]
    for comment in comments.all where comment.sentAt == nil {
      counts[comment.anchor.snapshotID, default: 0] += 1
    }
    self.counts = counts
    let others = history.snapshots.filter {
      $0.id != currentSnapshotID && counts[$0.id, default: 0] > 0
    }
    otherSnapshotCount = others.count
    otherCommentCount = others.reduce(0) { $0 + counts[$1.id, default: 0] }
    let currentIndex = history.snapshots.firstIndex { $0.id == currentSnapshotID }
    let older = currentIndex.map { index in
      others.filter { other in
        history.snapshots.firstIndex { $0.id == other.id }.map { $0 < index } ?? false
      }
    }
    nextOtherSnapshot = older?.last ?? others.last
  }

  func count(in snapshotID: DiffSnapshotID) -> Int {
    counts[snapshotID, default: 0]
  }
}

extension DiffViewerModel {
  var unsentCommentSummary: DiffUnsentCommentSummary {
    DiffUnsentCommentSummary(
      history: history, comments: comments, currentSnapshotID: currentSnapshot?.id)
  }
}
