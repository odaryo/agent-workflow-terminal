import Adapters
import Foundation
import Testing

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// `git --no-optional-locks --no-pager status --porcelain=v2 --branch --renames
// --untracked-files=normal -z`
@Suite("§17.1 status porcelain v2 の解析")
struct GitStatusPorcelainV2Tests {
  @Test("branch・rename・LF 入り path を解析する")
  func parsesFixture() throws {
    let result = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-branch-z.txt"))
    #expect(result.failures.isEmpty)
    #expect(result.status.branch?.ahead == 1)
    #expect(result.status.branch?.behind == 0)
    #expect(result.status.entries.count == 9)
    #expect(result.status.entries.contains(.untracked(path: "untracked\nwith newline.txt")))
    guard case .changed(let added) = result.status.entries[0],
      case .changed(let stagedPath) = result.status.entries[3],
      case .changed(let rename) = result.status.entries[4],
      case .changed(let tracked) = result.status.entries[6]
    else {
      Issue.record("changed entry の順序が異なる")
      return
    }
    #expect(added.indexStatus == .added)
    #expect(added.worktreeStatus == .unchanged)
    #expect(added.headMode == "000000")
    #expect(added.indexMode == "100644")
    #expect(added.headObject == String(repeating: "0", count: 40))
    #expect(stagedPath.path == "dir with space/staged新規.txt")
    #expect(rename.path == "newname.txt")
    #expect(rename.renameOrCopy?.originalPath == "oldname.txt")
    #expect(rename.renameOrCopy?.score == 100)
    #expect(tracked.indexStatus == .unchanged)
    #expect(tracked.worktreeStatus == .modified)
    #expect(tracked.worktreeMode == "100755")
    #expect(tracked.indexObject == "f384549cbeb481e437091320de6d1f2e15e11b4a")
  }
  @Test("detached と unmerged を保持する")
  func parsesVariants() throws {
    let detached = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-detached-z.txt"))
    let unmerged = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-unmerged-z.txt"))
    #expect(detached.failures.isEmpty)
    #expect(unmerged.failures.isEmpty)
    #expect(detached.status.branch?.isDetached == true)
    guard case .unmerged(let entry) = unmerged.status.entries.first else {
      Issue.record("unmerged ではない")
      return
    }
    #expect(entry.indexStatus == .unmerged)
    #expect(entry.worktreeStatus == .unmerged)
    #expect(entry.stage1Mode == "100644")
    #expect(entry.stage2Mode == "100644")
    #expect(entry.stage3Mode == "100644")
    #expect(entry.worktreeMode == "100644")
    #expect(entry.stage1Object == "df967b96a579e45a18b8251732d16804b2e56a55")
    #expect(entry.stage2Object == "ba2906d0666cf726c7eaadd2cd3db615dedfdf3a")
    #expect(entry.stage3Object == "e45c9c2666d44e0327c1f9c239a74c508336053e")
    #expect(entry.path == "c.txt")
  }

  @Test("ignored と変更なし fixture を解析する")
  func parsesIgnoredAndCleanFixtures() throws {
    let ignored = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-ignored-z.txt"))
    let clean = GitStatusPorcelainV2.parse(
      output: try fixture(named: "git-2.50.1-status-porcelain-v2-clean-z.txt"))
    #expect(ignored.failures.isEmpty)
    #expect(ignored.status.entries.contains(.ignored(path: "ignored.log")))
    #expect(clean.failures.isEmpty)
    #expect(clean.status.entries.isEmpty)
  }
  @Test("未知 header を無視し未知 record を部分失敗にする")
  func handlesFutureRecords() {
    let result = GitStatusPorcelainV2.parse(output: "# future value\0x value\0? ok\0")
    #expect(result.status.entries == [.untracked(path: "ok")])
    #expect(result.failures.count == 1)
  }

  @Test("branch ahead/behind の符号を検証する")
  func validatesAheadBehindSigns() {
    let result = GitStatusPorcelainV2.parse(output: "# branch.ab x1 y2\0")
    #expect(result.failures.first?.error == .invalidBranchAheadBehind("# branch.ab x1 y2"))
  }
  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
