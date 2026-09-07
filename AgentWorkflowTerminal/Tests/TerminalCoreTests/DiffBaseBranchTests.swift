import Testing

@testable import TerminalCore

@Suite("§9.1.1 base branch の決定")
struct DiffBaseBranchTests {
  @Test("ユーザーの明示的な選択が自動判定より優先される")
  func prefersUserSelection() {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: "release/1.0", upstream: "origin/feature", originHead: "origin/main")
        == .resolved(branch: "release/1.0", source: .userSelection))
  }

  @Test("選択が無ければ upstream、次に origin/HEAD を使う")
  func fallsBackInOrder() {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: nil, upstream: "origin/feature", originHead: "origin/main")
        == .resolved(branch: "origin/feature", source: .upstream))
    #expect(
      DiffBaseBranchResolver.resolve(userSelection: nil, upstream: nil, originHead: "origin/main")
        == .resolved(branch: "origin/main", source: .originHead))
  }

  @Test("どちらも解決できなければ未決定にする (main へ丸めない)")
  func doesNotFallBackToMain() {
    #expect(
      DiffBaseBranchResolver.resolve(userSelection: nil, upstream: nil, originHead: nil)
        == .undetermined)
  }

  @Test(
    "空白だけの値は解決できていないものとして扱う",
    arguments: ["", " ", "\t"])
  func treatsBlankAsAbsent(blank: String) {
    #expect(
      DiffBaseBranchResolver.resolve(userSelection: blank, upstream: blank, originHead: blank)
        == .undetermined)
    #expect(
      DiffBaseBranchResolver.resolve(userSelection: blank, upstream: blank, originHead: "origin/x")
        == .resolved(branch: "origin/x", source: .originHead))
  }

  @Test("解決済みの branch 名だけを取り出せる")
  func exposesBranchName() {
    #expect(
      DiffBaseBranch.resolved(branch: "origin/main", source: .upstream).branch == "origin/main")
    #expect(DiffBaseBranch.undetermined.branch == nil)
  }
}
