import Testing

@testable import TerminalCore

@Suite("§9.1.3 untracked ファイルの合成と Diff 表示モデル")
struct UnifiedDiffTests {
  @Test("untracked は全行追加になり、new 側の行番号だけを持つ")
  func synthesizesAllAddedLines() throws {
    let file = UntrackedFileDiff.addedFile(path: "new.txt", content: "a\nb\n")
    #expect(file.changeKind == .added)
    #expect(file.oldPath == nil)
    #expect(file.newPath == "new.txt")
    let hunk = try #require(file.hunks.first)
    #expect(hunk.oldStart == 0)
    #expect(hunk.oldCount == 0)
    #expect(hunk.newStart == 1)
    #expect(hunk.newCount == 2)
    #expect(hunk.lines.map(\.text) == ["a", "b"])
    #expect(hunk.lines.allSatisfy { $0.kind == .added && $0.oldLineNumber == nil })
    #expect(hunk.lines.map(\.newLineNumber) == [1, 2])
    #expect(hunk.lines.allSatisfy { !$0.isMissingTrailingNewline })
  }

  @Test("末尾に改行が無い untracked は最終行にその印を付ける")
  func marksMissingTrailingNewline() throws {
    let file = UntrackedFileDiff.addedFile(path: "n.txt", content: "a\nb")
    let lines = try #require(file.hunks.first?.lines)
    #expect(lines.count == 2)
    #expect(lines.map(\.isMissingTrailingNewline) == [false, true])
  }

  @Test("空の untracked ファイルは hunk を持たない")
  func emptyFileHasNoHunk() {
    #expect(UntrackedFileDiff.addedFile(path: "e.txt", content: "").content == .noContentChange)
  }

  @Test("中身を読めなかった untracked は理由を保ったまま行を持たない")
  func unreadableFileHasNoLines() {
    let file = UntrackedFileDiff.fileWithoutContent(path: "bin.dat", reason: .binary(byteCount: 7))
    #expect(file.content == .unreadable(.binary(byteCount: 7)))
    #expect(file.hunks.isEmpty)
  }

  /// §9.3 の変更検知は `UnifiedDiffCanonicalText` の値でしか動かない。ここは「今は何を
  /// 検知できないか」を固定するテストで、死角を塞ぐのは別 Issue (M4)。
  /// `.notReadable` になるのは、`status` が畳んだ untracked ディレクトリ (内部に `.git` を持つ等)
  /// と、`FileContentReader` が読めなかったファイル。
  @Test("`.notReadable` は中身もサイズも持たないので、内容が変わっても検知できない")
  func cannotDetectChangesInUnreadableFiles() {
    let before = UntrackedFileDiff.fileWithoutContent(path: "nested/", reason: .notReadable)
    let after = UntrackedFileDiff.fileWithoutContent(path: "nested/", reason: .notReadable)
    #expect(UnifiedDiffCanonicalText.text(of: before) == UnifiedDiffCanonicalText.text(of: after))
  }

  /// untracked の binary は `status` の一覧と `FileContentReader` のサイズしか観測しておらず、
  /// index の OID を持たない。塞ぐのは別 Issue (#211)。
  @Test("同じサイズのままの binary 書き換えは検知できない")
  func cannotDetectSameSizeBinaryRewrite() {
    let before = UntrackedFileDiff.fileWithoutContent(path: "b.dat", reason: .binary(byteCount: 32))
    let after = UntrackedFileDiff.fileWithoutContent(path: "b.dat", reason: .binary(byteCount: 32))
    #expect(UnifiedDiffCanonicalText.text(of: before) == UnifiedDiffCanonicalText.text(of: after))
    #expect(
      UnifiedDiffCanonicalText.text(
        of: UntrackedFileDiff.fileWithoutContent(path: "b.dat", reason: .tooLarge(byteCount: 32)))
        == UnifiedDiffCanonicalText.text(
          of: UntrackedFileDiff.fileWithoutContent(
            path: "b.dat", reason: .tooLarge(byteCount: 32))))
  }

  @Test("binary と大きすぎるファイルはサイズが変われば検知できる")
  func detectsSizeChangeOfUnreadFiles() {
    let smallBinary = UntrackedFileDiff.fileWithoutContent(
      path: "b.dat", reason: .binary(byteCount: 10))
    let largeBinary = UntrackedFileDiff.fileWithoutContent(
      path: "b.dat", reason: .binary(byteCount: 11))
    #expect(
      UnifiedDiffCanonicalText.text(of: smallBinary)
        != UnifiedDiffCanonicalText.text(of: largeBinary))
    #expect(
      UnifiedDiffCanonicalText.text(of: smallBinary)
        != UnifiedDiffCanonicalText.text(
          of: UntrackedFileDiff.fileWithoutContent(path: "b.dat", reason: .tooLarge(byteCount: 10)))
    )
  }

  @Test("差分行を持たないファイルの同一性は index の OID が担う")
  func distinguishesBinaryFilesByObject() {
    let before = UnifiedDiffFile(
      oldPath: "b.dat", newPath: "b.dat", changeKind: .modified, oldMode: "100644",
      newMode: "100644", oldObject: String(repeating: "a", count: 40),
      newObject: String(repeating: "b", count: 40), content: .binary)
    let after = UnifiedDiffFile(
      oldPath: "b.dat", newPath: "b.dat", changeKind: .modified, oldMode: "100644",
      newMode: "100644", oldObject: String(repeating: "a", count: 40),
      newObject: String(repeating: "c", count: 40), content: .binary)
    #expect(UnifiedDiffCanonicalText.text(of: before) != UnifiedDiffCanonicalText.text(of: after))
  }

  @Test("gitlink の mode を submodule として見分ける")
  func detectsSubmodule() {
    let file = UnifiedDiffFile(
      oldPath: "sub", newPath: "sub", changeKind: .modified, oldMode: "160000", newMode: "160000",
      content: .noContentChange)
    #expect(file.isSubmodule)
    #expect(
      !UnifiedDiffFile(
        oldPath: "a", newPath: "a", changeKind: .modified, oldMode: "100644", newMode: "100644",
        content: .noContentChange
      ).isSubmodule)
  }
}
