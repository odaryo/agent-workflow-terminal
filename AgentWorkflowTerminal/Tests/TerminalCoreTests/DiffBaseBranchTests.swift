import Testing

@testable import TerminalCore

@Suite("§9.1.1 base branch の決定")
struct DiffBaseBranchTests {
  @Test("ユーザーの明示的な選択が自動判定より優先される")
  func prefersUserSelection() {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: .local("release/1.0"), upstream: .remote("origin/feature"),
        originHead: .remote("origin/main"))
        == .resolved(branch: .local("release/1.0"), source: .userSelection))
  }

  @Test("選択が無ければ upstream、次に origin/HEAD を使う")
  func fallsBackInOrder() {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: nil, upstream: .remote("origin/feature"), originHead: .remote("origin/main"))
        == .resolved(branch: .remote("origin/feature"), source: .upstream))
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: nil, upstream: nil, originHead: .remote("origin/main"))
        == .resolved(branch: .remote("origin/main"), source: .originHead))
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
      DiffBaseBranchResolver.resolve(
        userSelection: .local(blank), upstream: .remote(blank), originHead: .remote(blank))
        == .undetermined)
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: .local(blank), upstream: .remote(blank), originHead: .remote("origin/x"))
        == .resolved(branch: .remote("origin/x"), source: .originHead))
  }

  @Test("解決済みの branch 名だけを取り出せる")
  func exposesBranchName() {
    #expect(
      DiffBaseBranch.resolved(branch: .remote("origin/main"), source: .upstream).branch
        == .remote("origin/main"))
    #expect(DiffBaseBranch.undetermined.branch == nil)
  }
}
