import Foundation
import TerminalCore
import Testing

@Suite("worktreeの安定ID (設計書 §3.5)")
struct WorktreeIdentityTests {

  @Test(
    "管理ディレクトリの絶対パスからIDを作れる",
    arguments: [
      "/Users/me/repo/.git",
      "/Users/me/repo/.git/worktrees/feature-a",
      "/",
    ]
  )
  func absolutePathIsAccepted(path: String) throws {
    let identity = try #require(WorktreeIdentity(rawValue: path))
    #expect(identity.rawValue == path)
  }

  @Test(
    "絶対パスでない文字列からはIDを作れない",
    arguments: [
      "",
      "repo/.git",
      "./.git",
      "~/repo/.git",
      " /Users/me/repo/.git",
    ]
  )
  func nonAbsolutePathIsRejected(path: String) {
    #expect(WorktreeIdentity(rawValue: path) == nil)
  }

  @Test("与えられた文字列を正規化しない")
  func rawValueIsKeptVerbatim() throws {
    let trailingSlash = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/a/"))
    let doubledSlash = try #require(WorktreeIdentity(rawValue: "/repo//.git/worktrees/a"))
    let dotSegment = try #require(WorktreeIdentity(rawValue: "/repo/./.git/worktrees/a"))

    #expect(trailingSlash.rawValue == "/repo/.git/worktrees/a/")
    #expect(doubledSlash.rawValue == "/repo//.git/worktrees/a")
    #expect(dotSegment.rawValue == "/repo/./.git/worktrees/a")
  }

  @Test("表記が違えば別のIDとして扱う")
  func distinctSpellingsAreDistinctIdentities() throws {
    let plain = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/a"))
    let trailingSlash = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/a/"))

    #expect(plain != trailingSlash)
    #expect(Set([plain, trailingSlash]).count == 2)
  }

  @Test("同じ文字列からは等しいIDになる")
  func sameSpellingIsEqual() throws {
    let lhs = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let rhs = try #require(WorktreeIdentity(rawValue: "/repo/.git"))

    #expect(lhs == rhs)
    #expect(Set([lhs, rhs]).count == 1)
  }

  @Test("JSONでは文字列そのものとして表現し、往復しても変わらない")
  func codableRoundTripUsesSingleValue() throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/Users/me/repo/.git"))
    let encoded = try JSONEncoder().encode([identity])

    #expect(String(decoding: encoded, as: UTF8.self) == #"["\/Users\/me\/repo\/.git"]"#)

    let decoded = try JSONDecoder().decode([WorktreeIdentity].self, from: encoded)
    #expect(decoded == [identity])
  }

  @Test("復号でも絶対パス検証を通す")
  func decodingRejectsNonAbsolutePath() {
    let encoded = Data(#"["repo/.git"]"#.utf8)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([WorktreeIdentity].self, from: encoded)
    }
  }
}
