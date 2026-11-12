import Foundation
import TerminalCore
import Testing

@Suite("§7.2・§12.3 Diff 区分の打ち切り")
struct DiffSectionTruncationTests {
  @Test("§12.3 打ち切りで表示ファイルが空でも差分無しにしない")
  func truncatedEmptySectionIsNotEmpty() {
    let truncation = DiffSectionTruncation(outputLimit: 128, firstOmittedPath: "a")
    let section = DiffOriginSection(origin: .staged, files: [], truncation: truncation)
    #expect(section.truncation == truncation)
    #expect(!snapshot(section: section).isEmpty)
  }

  @Test("§12.3 打ち切りの無い空の snapshot は空になる")
  func emptySectionWithoutTruncationIsEmpty() {
    let section = DiffOriginSection(origin: .staged, files: [])
    #expect(section.truncation == nil)
    #expect(snapshot(section: section).isEmpty)
  }

  private func snapshot(section: DiffOriginSection) -> DiffSnapshot {
    DiffSnapshot(
      id: DiffSnapshotID(rawValue: UUID()), subject: .commit(hash: "abc"),
      createdAt: Date(timeIntervalSince1970: 0), sections: [section],
      observation: DiffSnapshotObservation(headObject: "abc", files: []))
  }
}
