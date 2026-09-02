import Adapters
import Foundation
import Testing

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// `git --no-optional-locks diff --find-renames --raw --numstat -z HEAD`
@Suite("§17.1 diff file summary の解析")
struct GitDiffFileSummariesTests {
  @Test("raw と numstat を新 path で結合する")
  func parsesFixture() throws {
    let result = GitDiffFileSummaries.parse(
      output: try fixture(named: "git-2.50.1-diff-raw-numstat-z-head.txt"))
    #expect(result.failures.isEmpty); #expect(result.summaries.count == 6)
    let binary = try #require(result.summaries.first { $0.path == "bin.dat" })
    #expect(binary.lineCounts == .binary)
    let rename = try #require(result.summaries.first { $0.path == "newname.txt" })
    #expect(rename.originalPath == "oldname.txt"); #expect(rename.kind == .renamed(score: 69))
    #expect(rename.lineCounts == .text(insertions: 1, deletions: 1))
  }
  @Test("片側だけの path を failure にする")
  func reportsUnmatched() {
    let result = GitDiffFileSummaries.parse(output: ":100644 100644 abc def M\0a\0")
    #expect(result.summaries.isEmpty)
    #expect(result.failures.contains { $0.error == .missingNumstat("a") })
  }
  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
