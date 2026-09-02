import Adapters
import Foundation
import Testing

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// `git --no-optional-locks status --porcelain=v2 --branch -z`
@Suite("§17.1 status porcelain v2 の解析")
struct GitStatusPorcelainV2Tests {
  @Test("branch・rename・LF 入り path を解析する")
  func parsesFixture() throws {
    let result = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-branch-z.txt"))
    #expect(result.failures.isEmpty); #expect(result.status.branch?.ahead == 1)
    #expect(result.status.branch?.behind == 0)
    #expect(result.status.entries.count == 7)
    #expect(result.status.entries.contains(.untracked(path: "untracked\nwith newline.txt")))
    guard case .changed(let rename) = result.status.entries[3] else {
      Issue.record("rename ではない"); return
    }
    #expect(rename.renameOrCopy?.originalPath == "oldname.txt")
    #expect(rename.renameOrCopy?.score == 100)
  }
  @Test("detached と unmerged を保持する")
  func parsesVariants() throws {
    let detached = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-detached-z.txt"))
    let unmerged = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-unmerged-z.txt"))
    #expect(detached.status.branch?.isDetached == true)
    guard case .unmerged = unmerged.status.entries.first else {
      Issue.record("unmerged ではない"); return
    }
  }
  @Test("未知 header を無視し未知 record を部分失敗にする")
  func handlesFutureRecords() {
    let result = GitStatusPorcelainV2.parse(output: "# future value\0x value\0? ok\0")
    #expect(result.status.entries == [.untracked(path: "ok")]); #expect(result.failures.count == 1)
  }
  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
