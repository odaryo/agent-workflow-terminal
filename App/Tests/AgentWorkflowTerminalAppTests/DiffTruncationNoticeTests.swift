import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§7.2 / §12.3 Diff の打ち切り警告")
struct DiffTruncationNoticeTests {
  @Test("打ち切りが無ければ警告は無い")
  func noTruncation() {
    #expect(
      DiffViewerModel.truncationNotices(
        for: snapshot(sections: [DiffOriginSection(origin: .staged, files: [])])
      ).isEmpty)
  }

  @Test("staged の上限と git 出力順の最後のファイル、最初の未表示ファイルを1行に出す")
  func describesTruncatedSection() {
    let notices = DiffViewerModel.truncationNotices(
      for: snapshot(sections: [
        section(origin: .staged, paths: ["z.txt", "a.txt"], firstOmittedPath: "b.bin")
      ]))

    #expect(
      notices == [
        "staged の Diff が上限 (64 MiB) を超えたため、途中までを表示しています。"
          + "表示した最後のファイル: a.txt。表示していない最初のファイル: b.bin。"
          + "以降のファイルの変更は検知できません。"
      ])
  }

  @Test("0件で打ち切った区分は表示できたファイルが無いと伝える")
  func noDisplayedFiles() {
    let notices = DiffViewerModel.truncationNotices(
      for: snapshot(sections: [
        section(origin: .staged, paths: [], firstOmittedPath: "b.bin")
      ]))

    #expect(
      notices == [
        "staged の Diff が上限 (64 MiB) を超えたため、途中までを表示しています。"
          + "表示できたファイルはありません。表示していない最初のファイル: b.bin。"
          + "以降のファイルの変更は検知できません。"
      ])
  }

  @Test("未表示ファイル名を読めなかったときは名前を推測しない")
  func unknownOmittedPath() {
    let notices = DiffViewerModel.truncationNotices(
      for: snapshot(sections: [
        section(origin: .unstaged, paths: ["a.txt"], firstOmittedPath: nil)
      ]))

    #expect(
      notices == [
        "unstaged の Diff が上限 (64 MiB) を超えたため、途中までを表示しています。"
          + "表示した最後のファイル: a.txt。表示していないファイルの名前は読めませんでした。"
          + "以降のファイルの変更は検知できません。"
      ])
  }

  @Test("打ち切った区分ごとに警告を出し、上限は各区分の値から作る")
  func multipleSections() {
    let notices = DiffViewerModel.truncationNotices(
      for: snapshot(sections: [
        section(
          origin: .committed, paths: [], firstOmittedPath: nil, outputLimit: 2 * 1024 * 1024),
        DiffOriginSection(origin: .staged, files: []),
        section(origin: .unstaged, paths: [], firstOmittedPath: "b.bin", outputLimit: 1234),
      ]))

    #expect(notices.count == 2)
    #expect(notices.first?.hasPrefix("commit済み の Diff が上限 (2 MiB) を超えたため") == true)
    #expect(notices.last?.hasPrefix("unstaged の Diff が上限 (1234 バイト) を超えたため") == true)
  }

  private func section(
    origin: DiffChangeOrigin, paths: [String], firstOmittedPath: String?,
    outputLimit: Int = 64 * 1024 * 1024
  ) -> DiffOriginSection {
    DiffOriginSection(
      origin: origin,
      files: paths.map {
        UnifiedDiffFile(
          oldPath: $0, newPath: $0, changeKind: .modified, content: .noContentChange)
      },
      truncation: DiffSectionTruncation(
        outputLimit: outputLimit, firstOmittedPath: firstOmittedPath))
  }

  private func snapshot(sections: [DiffOriginSection]) -> DiffSnapshot {
    DiffSnapshot(
      id: DiffSnapshotID(rawValue: UUID()), subject: .commit(hash: "head"),
      createdAt: Date(timeIntervalSince1970: 0), sections: sections,
      observation: DiffSnapshotObservation(headObject: nil, files: []))
  }
}
