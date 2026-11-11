import Testing

@testable import Adapters

@Suite("git remote の名前一覧")
struct GitRemoteNamesTests {
  @Test(
    "改行で区切り、空行を落として名前をそのまま残す",
    arguments: [
      ("origin\nup/x\n日本\n", ["origin", "up/x", "日本"]),
      ("", []),
      ("origin", ["origin"]),
      ("\norigin\n\nup/x\n", ["origin", "up/x"]),
      (" origin \n", [" origin "]),
    ])
  func parses(output: String, expected: [String]) {
    #expect(GitRemoteNames.parse(output: output) == expected)
  }
}
