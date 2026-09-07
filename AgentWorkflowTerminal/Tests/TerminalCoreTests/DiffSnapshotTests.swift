import Foundation
import Testing

@testable import TerminalCore

@Suite("§9.3 snapshot の固定と変更検知")
struct DiffSnapshotTests {
  private let snapshotID = DiffSnapshotID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID())

  @Test("同じ観測値なら「変更された」と言わない")
  func reportsNoChangeForIdenticalObservation() {
    let observation = DiffSnapshotObservation(
      headObject: "h1",
      files: [
        DiffFileObservation(origin: .committed, path: "a.txt", fingerprint: "f1"),
        DiffFileObservation(origin: .unstaged, path: "b.txt", fingerprint: "f2"),
      ])
    let comparison = DiffSnapshotChangeDetection.compare(
      opened: observation, current: observation)
    #expect(comparison.head == .unchanged)
    #expect(comparison.fileChanges.isEmpty)
    #expect(!comparison.hasChanges)
  }

  @Test("内容・出現・消失をそれぞれ検知する")
  func detectsEachKindOfChange() {
    let opened = DiffSnapshotObservation(
      headObject: "h1",
      files: [
        DiffFileObservation(origin: .committed, path: "a.txt", fingerprint: "f1"),
        DiffFileObservation(origin: .unstaged, path: "gone.txt", fingerprint: "f2"),
      ])
    let current = DiffSnapshotObservation(
      headObject: "h1",
      files: [
        DiffFileObservation(origin: .committed, path: "a.txt", fingerprint: "CHANGED"),
        DiffFileObservation(origin: .untracked, path: "new.txt", fingerprint: "f3"),
      ])
    let comparison = DiffSnapshotChangeDetection.compare(opened: opened, current: current)
    #expect(comparison.head == .unchanged)
    #expect(
      Set(comparison.fileChanges) == [
        .modified(origin: .committed, path: "a.txt"),
        .disappeared(origin: .unstaged, path: "gone.txt"),
        .appeared(origin: .untracked, path: "new.txt"),
      ])
    #expect(comparison.hasChanges)
  }

  @Test("同じパスでも出所が違えば別のファイルとして扱う")
  func keepsOriginsSeparate() {
    let opened = DiffSnapshotObservation(
      headObject: "h1",
      files: [DiffFileObservation(origin: .staged, path: "a.txt", fingerprint: "f1")])
    let current = DiffSnapshotObservation(
      headObject: "h1",
      files: [DiffFileObservation(origin: .unstaged, path: "a.txt", fingerprint: "f1")])
    let comparison = DiffSnapshotChangeDetection.compare(opened: opened, current: current)
    #expect(
      Set(comparison.fileChanges) == [
        .disappeared(origin: .staged, path: "a.txt"),
        .appeared(origin: .unstaged, path: "a.txt"),
      ])
  }

  @Test("HEAD が動いたことを検知する")
  func detectsHeadMove() {
    let comparison = DiffSnapshotChangeDetection.compare(
      opened: DiffSnapshotObservation(headObject: "h1", files: []),
      current: DiffSnapshotObservation(headObject: "h2", files: []))
    #expect(comparison.head == .changed)
    #expect(comparison.hasChanges)
  }

  @Test("HEAD を観測できていない側があれば unchanged にも changed にも丸めない")
  func doesNotRoundUnobservedHead() {
    #expect(
      DiffSnapshotChangeDetection.compare(
        opened: DiffSnapshotObservation(headObject: nil, files: []),
        current: DiffSnapshotObservation(headObject: "h2", files: [])
      ).head == .unknown)
    #expect(
      DiffSnapshotChangeDetection.compare(
        opened: DiffSnapshotObservation(headObject: nil, files: []),
        current: DiffSnapshotObservation(headObject: nil, files: [])
      ).head == .unknown)
  }

  @Test("出所ごとに引ける")
  func looksUpBySection() {
    let snapshot = makeSnapshot()
    #expect(snapshot.file(origin: .unstaged, path: "a.txt")?.path == "a.txt")
    #expect(snapshot.file(origin: .staged, path: "a.txt") == nil)
    #expect(!snapshot.isEmpty)
  }

  @Test("Review 状態は Reviewing から始まり Reviewed へ移せる")
  func tracksReviewState() {
    var snapshot = makeSnapshot()
    #expect(snapshot.reviewState == .reviewing)
    snapshot.reviewState = .reviewed
    #expect(snapshot.reviewState == .reviewed)
  }

  private func makeSnapshot() -> DiffSnapshot {
    let file = UnifiedDiffFile(
      oldPath: "a.txt", newPath: "a.txt", changeKind: .modified,
      content: .hunks([
        UnifiedDiffHunk(
          oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, section: "",
          lines: [
            UnifiedDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
            UnifiedDiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "before"),
            UnifiedDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "after"),
          ])
      ]))
    return DiffSnapshot(
      id: snapshotID,
      subject: .base(branch: "origin/main", mergeBase: "abc"),
      createdAt: Date(timeIntervalSince1970: 0),
      sections: [
        DiffOriginSection(origin: .committed, files: []),
        DiffOriginSection(origin: .unstaged, files: [file]),
      ],
      observation: DiffSnapshotObservation(headObject: "h1", files: []))
  }
}
