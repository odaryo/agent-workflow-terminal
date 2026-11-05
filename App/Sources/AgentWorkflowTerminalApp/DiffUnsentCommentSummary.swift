import TerminalCore

struct DiffUnsentCommentSummary {
  private let counts: [DiffSnapshotID: Int]
  let otherSnapshotCount: Int
  let otherCommentCount: Int
  let latestOtherSnapshot: DiffSnapshot?

  var hasOtherUnsentComments: Bool { latestOtherSnapshot != nil }

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
    latestOtherSnapshot = others.last
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
