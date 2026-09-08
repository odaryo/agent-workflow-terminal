import Adapters
import Foundation
import TerminalCore
import Testing

// fixture は隔離 repository (`/private/tmp/awt-measure-*`) から git 2.50.1 で採取。
// `git --no-pager -c core.quotePath=false diff --no-ext-diff --no-textconv --find-renames
// --patch --no-color [--cached HEAD]`
@Suite("§9.1.3 unified diff (hunk) の解析")
struct UnifiedDiffPatchTests {
  @Test("binary・削除・変更・rename を1つの出力から取り出す")
  func parsesMixedPatch() throws {
    let result = UnifiedDiffPatch.parse(
      output: try fixture("git-2.50.1-diff-patch-cached-head.txt"))
    #expect(result.failures.isEmpty)
    #expect(result.files.map(\.path) == ["bin.dat", "del.txt", "keep.txt", "newname.txt"])

    let binary = try #require(result.files.first { $0.path == "bin.dat" })
    #expect(binary.content == .binary)
    #expect(binary.changeKind == .modified)
    #expect(binary.oldMode == "100644")

    let deleted = try #require(result.files.first { $0.path == "del.txt" })
    #expect(deleted.changeKind == .deleted)
    #expect(deleted.newPath == nil)
    #expect(deleted.oldMode == "100644")
    let deletedHunk = try #require(deleted.hunks.first)
    #expect(deletedHunk.oldStart == 1)
    #expect(deletedHunk.oldCount == 1)
    #expect(deletedHunk.newStart == 0)
    #expect(deletedHunk.newCount == 0)
    #expect(
      deletedHunk.lines == [
        UnifiedDiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "bye")
      ])

    let modified = try #require(result.files.first { $0.path == "keep.txt" })
    let hunk = try #require(modified.hunks.first)
    #expect(hunk.oldStart == 1)
    #expect(hunk.oldCount == 3)
    #expect(hunk.newStart == 1)
    #expect(hunk.newCount == 3)
    #expect(
      hunk.lines == [
        UnifiedDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "l1"),
        UnifiedDiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "l2"),
        UnifiedDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "l2 staged"),
        UnifiedDiffLine(kind: .context, oldLineNumber: 3, newLineNumber: 3, text: "l3"),
      ])

    let renamed = try #require(result.files.first { $0.path == "newname.txt" })
    #expect(renamed.changeKind == .renamed(from: "oldname.txt", similarity: 100))
    #expect(renamed.oldPath == "oldname.txt")
    #expect(renamed.content == .noContentChange)
  }

  @Test("mode 変更のみ・改行なし・非 ASCII・空白入り binary を落とさない")
  func parsesEdgeCases() throws {
    let result = UnifiedDiffPatch.parse(output: try fixture("git-2.50.1-diff-patch-edge.txt"))
    #expect(result.failures.isEmpty)
    #expect(result.files.map(\.path) == ["café.txt", "mode.sh", "nonl.txt", "with space.bin"])

    let modeOnly = try #require(result.files.first { $0.path == "mode.sh" })
    #expect(modeOnly.content == .noContentChange)
    #expect(modeOnly.oldMode == "100644")
    #expect(modeOnly.newMode == "100755")
    #expect(modeOnly.changeKind == .modified)

    let noNewline = try #require(result.files.first { $0.path == "nonl.txt" })
    let lines = try #require(noNewline.hunks.first?.lines)
    #expect(
      lines == [
        UnifiedDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "a"),
        UnifiedDiffLine(
          kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "b",
          isMissingTrailingNewline: true),
        UnifiedDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "b"),
        UnifiedDiffLine(
          kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "c",
          isMissingTrailingNewline: true),
      ])

    let spaced = try #require(result.files.first { $0.path == "with space.bin" })
    #expect(spaced.content == .binary)
    #expect(spaced.oldPath == "with space.bin")
    #expect(spaced.newPath == "with space.bin")
  }

  /// git は path に空白が含まれるとき、unified diff の規約として `---` / `+++` の path の後ろへ
  /// TAB を付ける (git 2.50.1 で実測)。quote された path には付かない。
  @Test("空白を含むパスの末尾 TAB を落とし、quote された値の TAB は本物として残す")
  func stripsTrailingTabFromMarkerPaths() throws {
    let result = UnifiedDiffPatch.parse(
      output: try fixture("git-2.50.1-diff-patch-space-in-path.txt"))
    #expect(result.failures.isEmpty)
    #expect(
      result.files.map(\.path) == ["plain.txt", "sp ace.txt", "tab\there.txt", "ワイド 名.txt"])

    let spaced = try #require(result.files.first { $0.path == "sp ace.txt" })
    #expect(spaced.oldPath == "sp ace.txt")
    #expect(spaced.newPath == "sp ace.txt")
    // status 由来の untracked と表現が食い違うと `file(origin:path:)` が外れる (§9.1.3 / #208)。
    #expect(!spaced.path.contains("\t"))
    #expect(!result.files.contains { ($0.oldPath ?? "").hasSuffix("\t") })

    let quoted = try #require(result.files.first { $0.path.hasPrefix("tab") })
    #expect(quoted.path == "tab\there.txt")
  }

  /// 分離子 TAB は quote の有無によらず、path に空白があれば付く (git 2.50.1 で実測:
  /// `--- "a/He said \"hi\" there.txt"\t`)。quote された値の後ろに TAB が来る形を落とすと、
  /// quote 解除も prefix の除去もされずリテラルが `path` に残る。
  @Test("空白と quote 強制文字が同居するパスでも quote 解除と prefix 除去が効く")
  func unquotesPathsThatAlsoCarrySeparatorTab() throws {
    let result = UnifiedDiffPatch.parse(
      output: try fixture("git-2.50.1-diff-patch-quoted-space-path.txt"))
    #expect(result.failures.isEmpty)
    #expect(
      result.files.map(\.path).sorted()
        == [
          "He said \"hi\" there.txt", "back\\slash and space.txt", "end with space .txt",
          "nihon\t語 x.txt", "plain.txt", "sp ace and\ttab.txt", "sp ace.txt", "tab\tmid.txt",
          "trailtab\t",
        ].sorted())
    // rename でないファイルで old と new が食い違うのは、prefix が剥がれていない兆候。
    #expect(result.files.allSatisfy { $0.oldPath == $0.newPath })
    #expect(!result.files.contains { $0.path.hasPrefix("\"") || $0.path.hasPrefix("b/") })

    // 剥がしすぎていないこと: 末尾が本物の TAB / 末尾が空白の名前は保つ。
    #expect(result.files.contains { $0.path == "trailtab\t" })
    #expect(result.files.contains { $0.path == "end with space .txt" })
  }

  @Test("--full-index の OID をそのまま保つ (core.abbrev で動かさない)")
  func keepsFullIndexObjects() throws {
    let result = UnifiedDiffPatch.parse(
      output: try fixture("git-2.50.1-diff-patch-space-in-path.txt"))
    let file = try #require(result.files.first)
    #expect(file.oldObject?.count == 40)
    #expect(file.newObject?.count == 40)
  }

  @Test("新規ファイルは old 側のパスを持たない")
  func parsesNewFile() throws {
    let result = UnifiedDiffPatch.parse(output: try fixture("git-2.50.1-diff-patch-new-file.txt"))
    #expect(result.failures.isEmpty)
    let file = try #require(result.files.first)
    #expect(file.changeKind == .added)
    #expect(file.oldPath == nil)
    #expect(file.newMode == "100644")
    #expect(file.hunks.first?.lines.map(\.newLineNumber) == [1, 2])
  }

  @Test("submodule は gitlink の mode として保持する")
  func parsesSubmodule() throws {
    let result = UnifiedDiffPatch.parse(output: try fixture("git-2.50.1-diff-patch-submodule.txt"))
    #expect(result.failures.isEmpty)
    let file = try #require(result.files.first)
    #expect(file.isSubmodule)
    #expect(file.hunks.first?.lines.count == 2)
  }

  @Test("`,s` を省略した hunk header の行数は 1 として扱う")
  func parsesOmittedHunkCounts() throws {
    let output = """
      diff --git a/a.txt b/a.txt
      index 1111111..2222222 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -3 +7 @@ func body()
      -old
      +new

      """
    let result = UnifiedDiffPatch.parse(output: output)
    #expect(result.failures.isEmpty)
    let hunk = try #require(result.files.first?.hunks.first)
    #expect(hunk.oldStart == 3)
    #expect(hunk.oldCount == 1)
    #expect(hunk.newStart == 7)
    #expect(hunk.newCount == 1)
    #expect(hunk.section == "func body()")
    #expect(hunk.lines.map(\.oldLineNumber) == [3, nil])
    #expect(hunk.lines.map(\.newLineNumber) == [nil, 7])
  }

  @Test("複数 hunk の行番号を hunk header から採番し直す")
  func renumbersAcrossHunks() throws {
    let output = """
      diff --git a/a.txt b/a.txt
      index 1111111..2222222 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -1,2 +1,2 @@
       one
      -two
      +TWO
      @@ -10,2 +10,3 @@
       ten
      +eleven
       twelve

      """
    let result = UnifiedDiffPatch.parse(output: output)
    #expect(result.failures.isEmpty)
    let hunks = try #require(result.files.first?.hunks)
    #expect(hunks.count == 2)
    #expect(hunks[1].lines.map(\.oldLineNumber) == [10, nil, 11])
    #expect(hunks[1].lines.map(\.newLineNumber) == [10, 11, 12])
  }

  @Test("hunk 本文中の `diff --git` を次のファイルと取り違えない")
  func doesNotSplitOnContentLine() throws {
    let output = """
      diff --git a/a.txt b/a.txt
      index 1111111..2222222 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -1,1 +1,2 @@
       diff --git a/x b/x
      +added

      """
    let result = UnifiedDiffPatch.parse(output: output)
    #expect(result.failures.isEmpty)
    #expect(result.files.count == 1)
    #expect(result.files.first?.hunks.first?.lines.count == 2)
  }

  @Test("壊れた1ファイルで全体を失わない")
  func keepsPartialSuccess() throws {
    let output = """
      diff --git a/broken.txt b/broken.txt
      @@ not a hunk header @@
      diff --git a/ok.txt b/ok.txt
      index 1111111..2222222 100644
      --- a/ok.txt
      +++ b/ok.txt
      @@ -1 +1 @@
      -x
      +y

      """
    let result = UnifiedDiffPatch.parse(output: output)
    #expect(result.files.map(\.path) == ["ok.txt"])
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.error == .invalidHunkHeader("@@ not a hunk header @@"))
    #expect(result.failures.first?.lineNumber == 2)
  }

  @Test("宣言された行数に足りない hunk を失敗として残す")
  func reportsTruncatedHunk() throws {
    let output = """
      diff --git a/a.txt b/a.txt
      index 1111111..2222222 100644
      --- a/a.txt
      +++ b/a.txt
      @@ -1,3 +1,3 @@
       one

      """
    let result = UnifiedDiffPatch.parse(output: output)
    #expect(result.files.isEmpty)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.error == .truncatedHunk(remainingOld: 2, remainingNew: 2))
  }

  /// 競合中のパスは patch 形式では出ないので、`files` へは入れずに `unmergedPaths` へ残す。
  /// 汎用の解析失敗にすると UI が「解析できていません」だけを出す (Issue #242)。
  @Test("競合の combined diff と `* Unmerged path` を失敗にせず読み飛ばす")
  func recognizesUnmergedRecords() throws {
    let unstaged = UnifiedDiffPatch.parse(
      output: try fixture("git-2.50.1-diff-patch-conflict-unstaged.txt"))
    #expect(unstaged.failures.isEmpty)
    #expect(unstaged.files.map(\.path) == ["auto.txt"])
    #expect(unstaged.unmergedPaths == ["addadd.txt", "both.txt", "delmod.txt"])
    #expect(unstaged.files.first?.hunks.flatMap(\.lines).count == 3)

    // `--cached` は combined diff を出さず、通常ブロックの前後に1行レコードを挟む。
    let cached = UnifiedDiffPatch.parse(
      output: try fixture("git-2.50.1-diff-patch-conflict-cached-head.txt"))
    #expect(cached.failures.isEmpty)
    #expect(cached.files.map(\.path) == ["auto.txt"])
    #expect(cached.unmergedPaths == ["addadd.txt", "both.txt", "delmod.txt"])
  }

  @Test("競合が無ければ unmergedPaths は空")
  func leavesUnmergedPathsEmptyWithoutConflict() throws {
    let result = UnifiedDiffPatch.parse(
      output: try fixture("git-2.50.1-diff-patch-cached-head.txt"))
    #expect(result.unmergedPaths.isEmpty)
  }

  @Test("空の入力は失敗にしない")
  func acceptsEmptyOutput() {
    let result = UnifiedDiffPatch.parse(output: "")
    #expect(result.files.isEmpty)
    #expect(result.failures.isEmpty)
  }

  private func fixture(_ name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
