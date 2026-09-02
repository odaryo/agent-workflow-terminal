import Adapters
import Foundation
import Testing

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// `git --no-optional-locks --no-pager log -z --no-show-signature --encoding=UTF-8
// --format=<GitLog.format>`
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
    #expect(first.authorEmail == "taro@example.com")
    #expect(first.committerEmail == "c@example.com")
    #expect(first.authoredAt == Date(timeIntervalSince1970: 1_785_886_200))
    #expect(first.committedAt == Date(timeIntervalSince1970: 1_785_886_200))
    #expect(first.hash == "39362183c3727928329411f35d346ec9fcbf5bd2")
    #expect(first.abbreviatedHash == "3936218")
    #expect(first.subject == "chore: ahead コミット")
    #expect(first.rawBody == "chore: ahead コミット\n")
    #expect(result.commits[1].isMerge)
    #expect(result.commits.last?.parentHashes == [])
    #expect(
      result.commits.last?.rawBody
        == "feat: 初期コミット\n\n本文の1行目\n本文の2行目\n")
  }

  @Test("US 衝突を部分失敗にする")
  func rejectsFieldCollision() {
    let tooFew = GitLog.parse(output: "a\u{1F}b\0")
    let tooMany = GitLog.parse(
      output: Array(repeating: "field", count: 12).joined(separator: "\u{1F}") + "\0")
    #expect(tooFew.commits.isEmpty)
    #expect(tooFew.failures.first?.error == .invalidFieldCount(actual: 2))
    #expect(tooMany.failures.first?.error == .invalidFieldCount(actual: 12))
  }

  @Test("件数制限 fixture と SHA-256 OID を解析する")
  func parsesAdditionalFixtures() throws {
    let limited = GitLog.parse(output: try fixture(named: "git-2.50.1-log-z-max2.txt"))
    let sha256 = GitLog.parse(output: try fixture(named: "git-2.50.1-sha256-log-z.txt"))
    #expect(limited.failures.isEmpty)
    #expect(limited.commits.count == 2)
    #expect(sha256.failures.isEmpty)
    #expect(sha256.commits.count == 2)
    #expect(sha256.commits.first?.hash.count == 64)
    #expect(sha256.commits.first?.parentHashes.first?.count == 64)
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
