import Adapters
import Foundation
import Testing

// fixture は隔離 repository から git 2.50.1 で採取。
// `git for-each-ref --format=%(refname) refs/heads/ refs/remotes/`
@Suite("§9.1.1 base branch 候補の ref 名")
struct GitRefNamesTests {
  @Test("local と remote-tracking を分け、origin/HEAD を候補にしない")
  func parsesFixture() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "git-2.50.1-for-each-ref-refname.txt", withExtension: nil,
        subdirectory: "Fixtures"))
    let names = GitRefNameList.parse(
      output: String(decoding: try Data(contentsOf: url), as: UTF8.self))
    #expect(names.localBranches == ["feature", "main"])
    #expect(names.remoteBranches == ["origin/feature", "origin/main"])
    #expect(names.all.count == 4)
  }

  @Test("symbolic-ref の出力を merge-base へ渡せる短縮名にする")
  func shortensRemoteRef() {
    #expect(GitRefNameList.shortenRemoteRef("refs/remotes/origin/main\n") == "origin/main")
    #expect(GitRefNameList.shortenRemoteRef("refs/heads/main\n") == nil)
    #expect(GitRefNameList.shortenRemoteRef("") == nil)
  }
}
