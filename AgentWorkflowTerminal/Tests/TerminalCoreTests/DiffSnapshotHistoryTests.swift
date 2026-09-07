import Foundation
import Testing

@testable import TerminalCore

@Suite("§9.3 Refresh は上書きではなく新しい snapshot の作成")
struct DiffSnapshotHistoryTests {
  @Test("Refresh は既存要素を書き換えず追加し、旧 snapshot を取り出せる")
  func appendsWithoutReplacing() throws {
    var history = DiffSnapshotHistory()
    let first = makeSnapshot(id: 1, paths: ["a.txt"])
    let second = makeSnapshot(id: 2, paths: ["a.txt", "b.txt"])
    let appendedFirst = history.append(first)
    let appendedSecond = history.append(second)
    #expect(appendedFirst)
    #expect(appendedSecond)
    #expect(history.count == 2)
    #expect(history.latest?.id == second.id)
    let kept = try #require(history.snapshot(first.id))
    #expect(kept == first)
    #expect(kept.section(.unstaged)?.files.map(\.path) == ["a.txt"])
    #expect(history.snapshots.map(\.id) == [first.id, second.id])
  }

  @Test("ID が重複する snapshot は追加せず、既存を壊さない")
  func rejectsDuplicateIDs() {
    var history = DiffSnapshotHistory()
    let appended = history.append(makeSnapshot(id: 1, paths: ["a.txt"]))
    let duplicate = history.append(makeSnapshot(id: 1, paths: ["hijacked.txt"]))
    #expect(appended)
    #expect(!duplicate)
    #expect(history.count == 1)
    #expect(history.latest?.section(.unstaged)?.files.map(\.path) == ["a.txt"])
  }

  @Test("Review 状態の変更は対象の snapshot だけに効く")
  func updatesOnlyTargetReviewState() throws {
    var history = DiffSnapshotHistory()
    let first = makeSnapshot(id: 1, paths: ["a.txt"])
    let second = makeSnapshot(id: 2, paths: ["b.txt"])
    history.append(first)
    history.append(second)

    let updated = history.setReviewState(.reviewed, for: first.id)
    let missing = history.setReviewState(.reviewed, for: DiffSnapshotID(rawValue: UUID()))
    #expect(updated)
    #expect(!missing)
    #expect(history.snapshot(first.id)?.reviewState == .reviewed)
    #expect(history.snapshot(second.id)?.reviewState == .reviewing)
  }

  @Test("空の履歴は latest を持たない")
  func startsEmpty() {
    let history = DiffSnapshotHistory()
    #expect(history.isEmpty)
    #expect(history.latest == nil)
    #expect(history.snapshots.isEmpty)
  }

  private func makeSnapshot(id: UInt8, paths: [String]) -> DiffSnapshot {
    let uuid =
      UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02X", id))") ?? UUID()
    return DiffSnapshot(
      id: DiffSnapshotID(rawValue: uuid),
      subject: .base(branch: "origin/main", mergeBase: "abc"),
      createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
      sections: [
        DiffOriginSection(
          origin: .unstaged,
          files: paths.map {
            UnifiedDiffFile(
              oldPath: $0, newPath: $0, changeKind: .modified, content: .noContentChange)
          })
      ],
      observation: DiffSnapshotObservation(headObject: "h1", files: []))
  }
}
