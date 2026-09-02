import Adapters
import Foundation
import Testing

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// `git --no-optional-locks --no-pager diff --no-ext-diff --no-textconv --find-renames
// --raw --numstat --no-abbrev -z HEAD`
@Suite("§17.1 diff file summary の解析")
struct GitDiffFileSummariesTests {
  @Test("raw と numstat を新 path で結合する")
  func parsesFixture() throws {
    let result = GitDiffFileSummaries.parse(
      output: try fixture(named: "git-2.50.1-diff-raw-numstat-z-head.txt"))
    #expect(result.failures.isEmpty)
    #expect(result.summaries.count == 7)
    let added = try #require(result.summaries.first { $0.path == ".gitignore" })
    #expect(added.kind == .added)
    #expect(added.sourceMode == "000000")
    #expect(added.destinationMode == "100644")
    #expect(added.sourceObject == String(repeating: "0", count: 40))
    #expect(added.destinationObject == "2378f14e9b0cb8716fd3bf612f280ccbf377505a")
    let binary = try #require(result.summaries.first { $0.path == "bin.dat" })
    #expect(binary.lineCounts == .binary)
    #expect(binary.kind == .modified)
    #expect(binary.destinationObject == String(repeating: "0", count: 40))
    let deleted = try #require(result.summaries.first { $0.path == "deleted.txt" })
    #expect(deleted.kind == .deleted)
    #expect(deleted.destinationMode == "000000")
    let spaced = try #require(
      result.summaries.first { $0.path == "dir with space/staged新規.txt" })
    #expect(spaced.kind == .added)
    let rename = try #require(result.summaries.first { $0.path == "newname.txt" })
    #expect(rename.originalPath == "oldname.txt")
    #expect(rename.kind == .renamed(score: 69))
    #expect(rename.lineCounts == .text(insertions: 1, deletions: 1))
    let tab = try #require(result.summaries.first { $0.path == "tab\there.txt" })
    #expect(tab.lineCounts == .text(insertions: 1, deletions: 1))
    let modified = try #require(result.summaries.first { $0.path == "tracked.txt" })
    #expect(modified.kind == .modified)
    #expect(modified.sourceMode == "100644")
    #expect(modified.destinationMode == "100755")
  }
  @Test("片側だけの path を failure にする")
  func reportsUnmatched() {
    let result = GitDiffFileSummaries.parse(output: ":100644 100644 abc def M\0a\0")
    #expect(result.summaries.isEmpty)
    #expect(result.failures.contains { $0.error == .missingNumstat("a") })
  }

  @Test("壊れた raw entry の path を飛ばして後続 entry を回復する")
  func recoversAfterInvalidRaw() {
    let output =
      ":100644 broken M\0broken.txt\0"
      + ":100644 100644 aaa bbb M\0good.txt\0"
      + "1\t0\tbroken.txt\0"
      + "1\t0\tgood.txt\0"
    let result = GitDiffFileSummaries.parse(output: output)
    #expect(result.summaries.map(\.path) == ["good.txt"])
    #expect(result.failures.count == 2)
    #expect(result.failures.contains { $0.error == .invalidRawRecord(":100644 broken M") })
  }

  @Test("壊れた rename raw の2 path を飛ばして後続 entry を回復する")
  func recoversAfterInvalidRenameRaw() {
    let output =
      ":100644 100644 aaa R09\0old.txt\0new.txt\0"
      + ":100644 100644 aaa bbb M\0good.txt\0"
      + "1\t0\tgood.txt\0"
    let result = GitDiffFileSummaries.parse(output: output)
    #expect(result.summaries.map(\.path) == ["good.txt"])
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.recordNumber == 1)
    #expect(result.failures.first?.record == ":100644 100644 aaa R09")
    #expect(result.failures.first?.error == .invalidRawRecord(":100644 100644 aaa R09"))
  }

  @Test("SHA-256 の完全長 object を保持する")
  func parsesSHA256Fixture() throws {
    // diff parser は OID 長を検証しないため、SHA-256 fixture の往復確認だけを目的とする。
    let result = GitDiffFileSummaries.parse(
      output: try fixture(named: "git-2.50.1-sha256-diff-raw-numstat-z.txt"))
    let summary = try #require(result.summaries.first)
    #expect(result.failures.isEmpty)
    #expect(summary.sourceObject.count == 64)
    #expect(summary.destinationObject.count == 64)
  }
  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
