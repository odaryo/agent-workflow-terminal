import Adapters
import Foundation
import Testing

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// `git --no-optional-locks worktree list --porcelain -z`
@Suite("§17.1 worktree list の解析")
struct GitWorktreeListTests {
  @Test("linked worktree と属性を解析する")
  func parsesFixture() throws {
    let result = GitWorktreeList.parse(
      output: try fixture(named: "git-2.50.1-worktree-list-porcelain-z.txt"))
    #expect(result.failures.isEmpty)
    #expect(result.entries.count == 4)
    #expect(result.entries[0].path.hasSuffix("/repo"))
    #expect(result.entries[0].head == "39362183c3727928329411f35d346ec9fcbf5bd2")
    #expect(!result.entries[0].isBare)
    #expect(result.entries[1].lockedReason == "手動で保護中")
    #expect(result.entries[2].isDetached)
    #expect(result.entries[3].branch == "refs/heads/feat/日本語🚀")
    #expect(result.entries.allSatisfy { $0.prunableReason == nil })
  }
  @Test("bare fixture は HEAD と branch を持たない")
  func parsesBareFixture() throws {
    let result = GitWorktreeList.parse(
      output: try fixture(named: "git-2.50.1-worktree-list-porcelain-z-bare.txt"))
    let entry = try #require(result.entries.first)
    #expect(result.failures.isEmpty)
    #expect(entry.isBare)
    #expect(entry.head == nil)
    #expect(entry.branch == nil)
    #expect(entry.path.hasSuffix("/origin.git"))
  }
  @Test("理由なし locked と属性なしを区別する")
  func distinguishesLockPresence() {
    let result = GitWorktreeList.parse(output: "worktree /a\0locked\0\0worktree /b\0\0")
    #expect(result.entries.map(\.lockedReason) == ["", nil])
  }
  @Test("worktree 欠落だけを failure にする")
  func partiallyFails() {
    #expect(
      GitWorktreeList.parse(output: "HEAD abc\0\0worktree /ok\0unknown x\0\0").entries.count == 1)
  }
  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
