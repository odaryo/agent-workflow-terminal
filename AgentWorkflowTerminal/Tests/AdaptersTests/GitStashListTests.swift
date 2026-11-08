import Foundation
import Testing

@testable import Adapters

// git 2.50.1 の隔離 repository で `git stash list --format=%gs` を採取。
@Suite("§3.4 Close の対象 branch の stash 件数")
struct GitStashListTests {
  @Test(
    "通常・件名指定・detached の stash を branch 短縮名の完全一致で数える",
    arguments: zip(["feature/x", "main", "feature", "feature/xy", "missing"], [2, 1, 0, 0, 0]))
  func countsMatchingBranch(branch: String, expected: Int) throws {
    let output = try fixture("git-2.50.1-stash-list-subjects.txt")

    #expect(GitStashList.count(output: output, branch: branch) == expected)
  }

  @Test("メッセージ内のコロンを branch の区切りとして数え直さない")
  func preservesColonsInMessage() throws {
    let output = try fixture("git-2.50.1-stash-list-subjects.txt")
    let subject = try #require(output.split(separator: "\n").first { $0.hasPrefix("On ") })

    #expect(subject == "On feature/x: my note: with colon")
    #expect(GitStashList.count(output: String(subject), branch: "feature/x") == 1)
    #expect(GitStashList.count(output: String(subject), branch: "feature/x: my note") == 0)
  }

  @Test("stash store の任意の件名は数えず、読める行の件数を残す")
  func skipsCustomSubject() throws {
    let custom = try fixture("git-2.50.1-stash-list-custom-subject.txt")
    let standard = try fixture("git-2.50.1-stash-list-subjects.txt")

    #expect(GitStashList.count(output: custom, branch: "feature/x") == 0)
    #expect(GitStashList.count(output: custom + standard, branch: "feature/x") == 2)
  }

  @Test(
    "想定外の形の行を数えない",
    arguments: ["WIP on feature/x", "On feature/x", "feature/x: note", "WIP on feature/xy: note"])
  func skipsUnexpectedSubject(output: String) {
    #expect(GitStashList.count(output: output, branch: "feature/x") == 0)
  }

  @Test("空の出力は0件")
  func countsEmptyOutput() {
    #expect(GitStashList.count(output: "", branch: "feature/x") == 0)
  }

  @Test(
    "メッセージや branch 名が結合文字で始まっても数える",
    arguments: [
      ("On feature/x: \u{301}note", "feature/x"),
      ("WIP on feature/x: \u{301}note", "feature/x"),
      ("On \u{301}x: note", "\u{301}x"),
      ("WIP on \u{301}x: note", "\u{301}x"),
    ])
  func countsSubjectsStartingWithCombiningMark(output: String, branch: String) {
    #expect(GitStashList.count(output: output, branch: branch) == 1)
  }

  @Test(
    "正準等価でも UTF-8 が異なる branch の stash は数えない",
    arguments: [
      ("caf\u{E9}", "cafe\u{301}"),
      ("cafe\u{301}", "caf\u{E9}"),
    ])
  func distinguishesCanonicalEquivalentBranches(stashedBranch: String, branch: String) {
    #expect(GitStashList.count(output: "On \(stashedBranch): note", branch: branch) == 0)
    #expect(GitStashList.count(output: "WIP on \(stashedBranch): note", branch: branch) == 0)
  }

  private func fixture(_ name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
