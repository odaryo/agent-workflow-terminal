import Foundation
import Testing

@testable import Adapters

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// `git --no-optional-locks log -z --format=<GitLog.format>`
@Suite("§17.1 git log の解析")
struct GitLogTests {
  @Test("format と実レコードを欠落なく解析する")
  func parsesFixture() throws {
    #expect(GitLog.format == "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%s%x1f%B")
    let result = GitLog.parse(output: try fixture(named: "git-2.50.1-log-z.txt"))
    let first = try #require(result.commits.first)
    #expect(result.failures.isEmpty)
    #expect(result.commits.count == 5)
    #expect(first.authorName == "山田 太郎🚀")
    #expect(first.rawBody.hasSuffix("\n"))
    #expect(result.commits[1].isMerge)
    #expect(result.commits.last?.parentHashes == [])
  }

  @Test("US 衝突を部分失敗にする")
  func rejectsFieldCollision() {
    let result = GitLog.parse(output: "a\u{1F}b\0")
    #expect(result.commits.isEmpty)
    #expect(result.failures.first?.error == .invalidFieldCount(actual: 2))
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
