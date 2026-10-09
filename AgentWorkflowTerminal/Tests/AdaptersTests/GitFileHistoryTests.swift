import Adapters
import Foundation
import Testing

// fixture は隔離 repository (`GIT_CONFIG_GLOBAL=/dev/null`) から 2.50.1 (ローカル) と
// 2.55.0 (CI の runner。brew bottle を /private/tmp へ隔離展開) の両方で採取した。
// `git --no-optional-locks -C <root> --no-pager log -z --no-show-signature --encoding=UTF-8
// --follow --find-renames --diff-merges=first-parent --name-status --format=<GitFileHistory.format>
// --max-count=201 HEAD -- ':(literal)src/new name é.txt'`
// 履歴: root → 変更 → rename (`src/old name ä.txt` → `src/new name é.txt`) → 分岐して両側で変更 →
// merge。author 名と summary にタブ・非 ASCII・制御文字 (US / RS を含む) を入れてある。
@Suite("§7.3 ファイル単位の Git 履歴の解析")
struct GitFileHistoryTests {
  private static let versions = ["2.50.1", "2.55.0"]

  @Test("rename を挟んだ履歴を、各 commit 時点のパスとともに解析する", arguments: versions)
  func parsesFollowedHistory(version: String) throws {
    let result = GitFileHistory.parse(
      output: try fixture(named: "git-\(version)-log-follow-name-status-z.txt"))

    #expect(result.failures.isEmpty)
    #expect(
      result.entries.map(\.abbreviatedCommitID) == [
        "e13aafb", "91f55f2", "066cbda", "2f9888f", "afe078f", "ec8f58e",
      ])
    #expect(
      result.entries.map { $0.changes.map(\.path) } == [
        ["src/new name é.txt"], ["src/new name é.txt"], ["src/new name é.txt"],
        ["src/new name é.txt"], ["src/old name ä.txt"], ["src/old name ä.txt"],
      ])

    let rename = try #require(result.entries.first { $0.abbreviatedCommitID == "2f9888f" })
    #expect(
      rename.changes == [
        GitFileHistoryChange(
          kind: .renamed(score: 100), path: "src/new name é.txt",
          previousPath: "src/old name ä.txt")
      ])
    #expect(rename.authoredAt == Date(timeIntervalSince1970: 1_767_416_400))

    let root = try #require(result.entries.last)
    #expect(root.parentIDs.isEmpty)
    #expect(root.changes.map(\.kind) == [.added])
    #expect(root.summary == "root: 初回")
  }

  @Test("merge commit は第1親との差分として1件だけ現れる", arguments: versions)
  func parsesMergeAsSingleEntry(version: String) throws {
    let result = GitFileHistory.parse(
      output: try fixture(named: "git-\(version)-log-follow-name-status-z.txt"))
    let merge = try #require(result.entries.first)

    #expect(merge.isMerge)
    #expect(
      merge.parentIDs == [
        "91f55f2e2193817b1b8a34342f3c6dd3259d41f8", "066cbda57bcb458662f1124dd261c16ed25df049",
      ])
    #expect(merge.changes.map(\.kind) == [.modified])
    #expect(result.entries.filter { $0.commitID == merge.commitID }.count == 1)
  }

  @Test("author 名と summary の空白・タブ・非 ASCII・制御文字をそのまま保持する", arguments: versions)
  func keepsControlCharacters(version: String) throws {
    let result = GitFileHistory.parse(
      output: try fixture(named: "git-\(version)-log-follow-name-status-z.txt"))
    let tabbed = try #require(result.entries.first { $0.abbreviatedCommitID == "afe078f" })
    let side = try #require(result.entries.first { $0.abbreviatedCommitID == "066cbda" })

    #expect(tabbed.authorName == "Tab\tAuthor 日本")
    #expect(tabbed.summary == "summary\twith tab \u{01}ctl \u{1B}[31m esc 非ASCII")
    // US / RS はフィールド区切りに使っていないので、値の一部として残る。
    #expect(side.authorName == "Ctl\u{01}\u{1F}Side")
    #expect(side.summary == "side\u{1F}change\u{1E}rs")
  }

  /// `--no-walk` で、指定した pathspec に触れない commit を1件だけ求めた場合。2.50.1 は何も
  /// 出さず、2.55.0 は name-status の無いヘッダだけを出す (実測)。
  @Test("pathspec に触れない commit の出力は版数で異なり、どちらも解析できる")
  func parsesUntouchedNoWalk() throws {
    let old = GitFileHistory.parse(
      output: try fixture(named: "git-2.50.1-log-no-walk-untouched-z.txt"))
    let new = GitFileHistory.parse(
      output: try fixture(named: "git-2.55.0-log-no-walk-untouched-z.txt"))

    #expect(old.records.isEmpty)
    #expect(new.failures.isEmpty)
    #expect(new.entries.count == 1)
    #expect(new.entries.first?.changes == [])
    #expect(new.entries.first?.summary == "merge side")
  }

  @Test("壊れたヘッダは部分失敗にし、後続のレコードを失わない")
  func reportsBrokenHeaderAndContinues() {
    let good =
      "\(String(repeating: "a", count: 40))\0aaaaaaa\0\0n\02026-01-01T00:00:00Z\0s\0\nA\0p\0"
    let broken = "\(String(repeating: "b", count: 40))\0bbbbbbb\0\0n\0not a date\0s\0\nM\0p\0"
    let result = GitFileHistory.parse(output: broken + good)

    #expect(result.entries.map(\.abbreviatedCommitID) == ["aaaaaaa"])
    #expect(result.failures.map(\.recordNumber) == [1])
    #expect(result.failures.first?.error == .invalidAuthoredAt("not a date"))
  }

  @Test("途中で切れた出力は、切れたレコードだけを失敗にする")
  func reportsTruncatedRecord() {
    let good =
      "\(String(repeating: "a", count: 40))\0aaaaaaa\0\0n\02026-01-01T00:00:00Z\0s\0\nA\0p\0"
    let truncated = "\(String(repeating: "c", count: 40))\0ccccccc\0\0n\0"
    let rename =
      "\(String(repeating: "d", count: 40))\0ddddddd\0\0n\02026-01-01T00:00:00Z\0s\0\nR100\0old\0"

    let headerCut = GitFileHistory.parse(output: good + truncated)
    let pathCut = GitFileHistory.parse(output: good + rename)

    #expect(headerCut.entries.count == 1)
    #expect(headerCut.failures.first?.error == .truncatedHeader(fieldCount: 4))
    #expect(pathCut.entries.count == 1)
    #expect(pathCut.failures.first?.error == .missingPath(status: "R100"))
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
