import TerminalCore
import Testing

@Suite("tmux session名の導出 (設計書 §3.5)")
struct TmuxSessionNameTests {

  // MARK: - Helpers

  /// hash 部分の期待値は `printf '%s' <安定IDのパス> | shasum -a 256 | cut -c1-8` で別途求めた値。
  /// 実装と同じ手順で計算すると、実装の誤りをテストが追認してしまうため。
  private static let taskIdentityPath = "/Users/me/repo/.git/worktrees/feature-a"
  private static let taskIdentityHash8 = "3f250649"
  private static let projectRootIdentityPath = "/Users/me/repo/.git"
  private static let projectRootIdentityHash8 = "3bd194b8"
  private static let bareRepositoryIdentityPath = "/srv/myrepo.git"
  private static let bareRepositoryIdentityHash8 = "931cf76b"

  private func name(_ identityPath: String) throws -> TmuxSessionName {
    TmuxSessionName(identity: try #require(WorktreeIdentity(rawValue: identityPath)))
  }

  /// slug 自体が `-` を含み得るので、末尾8桁の hash とその直前の `-` を落として切り出す。
  private func slug(of name: TmuxSessionName) throws -> String {
    let body = try #require(name.rawValue.hasPrefix("awt-") ? name.rawValue.dropFirst(4) : nil)
    let hash8 = body.suffix(8)

    #expect(hash8.count == 8)
    #expect(hash8.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(body.dropLast(8).hasSuffix("-"))

    return String(body.dropLast(9))
  }

  // MARK: - 形式

  @Test("awt-<slug>-<安定IDのSHA-256先頭8桁> の形になる")
  func nameFormat() throws {
    #expect(try name(Self.taskIdentityPath).rawValue == "awt-feature-a-\(Self.taskIdentityHash8)")
  }

  @Test("Project Rootでは `.git` ではなくrepositoryのディレクトリ名をslugにする")
  func projectRootUsesRepositoryDirectoryName() throws {
    #expect(
      try name(Self.projectRootIdentityPath).rawValue
        == "awt-repo-\(Self.projectRootIdentityHash8)"
    )
  }

  @Test("bare repositoryの `<repo>.git` は `_git` 分岐に入らない")
  func bareRepositoryKeepsItsOwnName() throws {
    #expect(
      try name(Self.bareRepositoryIdentityPath).rawValue
        == "awt-myrepo_git-\(Self.bareRepositoryIdentityHash8)"
    )
  }

  @Test("bare repositoryのlinked worktreeは通常どおり管理ディレクトリ名をslugにする")
  func bareRepositoryLinkedWorktree() throws {
    #expect(try slug(of: name("/srv/myrepo.git/worktrees/bare-wt")) == "bare-wt")
  }

  // MARK: - 決定性 (§3.3 Resume の前提)

  @Test("同じ安定IDからは常に同じ名前が出る")
  func derivationIsDeterministic() throws {
    #expect(try name(Self.taskIdentityPath) == (try name(Self.taskIdentityPath)))
  }

  /// git 2.50.1 の隔離リポジトリで実測した値。`git worktree add -b wt-feat ../wt-feat` のあと
  /// `checkout -b feat2` しても `git worktree move ../wt-feat ../wt-moved` しても
  /// `rev-parse --absolute-git-dir` は `<repo>/main/.git/worktrees/wt-feat` のまま変わらない
  /// (作業ツリーは `wt-moved` へ移り、branch は `feat2` になっている)。
  @Test("branch切替と `git worktree move` の後も安定IDが同じなので名前は変わらない")
  func nameSurvivesBranchSwitchAndMove() throws {
    let beforeAnyChange = try name("/repo/main/.git/worktrees/wt-feat")
    let afterCheckoutAndMove = try name("/repo/main/.git/worktrees/wt-feat")

    #expect(beforeAnyChange == afterCheckoutAndMove)
    #expect(try slug(of: afterCheckoutAndMove) == "wt-feat")
  }

  @Test("slugが同じでも安定IDが違えば別の名前になる")
  func sameSlugWithDifferentIdentityYieldsDifferentName() throws {
    let lhs = try name("/a/.git/worktrees/shared")
    let rhs = try name("/b/.git/worktrees/shared")

    #expect(lhs != rhs)
    #expect(lhs.rawValue == "awt-shared-4a577aa5")
    #expect(rhs.rawValue == "awt-shared-209c4b06")
  }

  // MARK: - slug の正規化

  /// 置換は Unicode スカラ単位で行う。書記素クラスタの分割規則は Unicode の版に依存し、
  /// Darwin では Swift stdlib が OS 側にあるため、Character 単位だと **OS 更新で同じ安定 ID から
  /// 別の名前が出る**。それは §3.5 が防ごうとしている二重 session 生成そのものになる。
  /// (実測: `x👨‍👩‍👧y` は Character 数 3 / スカラ数 7)
  @Test(
    "[A-Za-z0-9_-] 以外のUnicodeスカラを `_` へ置換する",
    arguments: [
      ("/r/.git/worktrees/Ab9_-", "Ab9_-"),
      ("/r/.git/worktrees/feat ure", "feat_ure"),
      ("/r/.git/worktrees/feat\\ure", "feat_ure"),
      ("/r/.git/worktrees/a+b=c", "a_b_c"),
      ("/r/.git/worktrees/機能追加", "____"),
      // ZWJ 連結の絵文字は1書記素だが7スカラ。結合文字も独立したスカラとして置換される。
      ("/r/.git/worktrees/x👨‍👩‍👧y", "x_____y"),
      ("/r/.git/worktrees/caf\u{00E9}", "caf_"),
      ("/r/.git/worktrees/cafe\u{0301}", "cafe_"),
    ]
  )
  func nonAllowedScalarsBecomeUnderscore(identityPath: String, expectedSlug: String) throws {
    #expect(try slug(of: name(identityPath)) == expectedSlug)
  }

  /// 「同じ安定 ID からは常に同じ名前」の対偶。安定 ID の等価性が `String` の正準等価だった頃は、
  /// 等しい ID から `awt-caf_-9e18cdc2` と `awt-caf_-281659d9` の2つの名前が出ていた (実測)。
  @Test("安定IDが等しいことと、導出される名前が等しいことは一致する")
  func identityEqualityMatchesNameEquality() throws {
    let composed = try #require(WorktreeIdentity(rawValue: "/r/.git/worktrees/caf\u{00E9}"))
    let decomposed = try #require(WorktreeIdentity(rawValue: "/r/.git/worktrees/cafe\u{0301}"))

    #expect(
      (composed == decomposed)
        == (TmuxSessionName(identity: composed) == TmuxSessionName(identity: decomposed)))
  }

  /// `od.d na:me` という作業ツリーを作ると git 2.50.1 は管理ディレクトリを `od.d-na-me` にする。
  /// 空白と `:` は `-` へ置換するが `.` はそのまま残すため、`.` の除去はこちらの責務になる。
  @Test(
    "`.` と `:` は生成名に現れない (tmux 3.4 の実測制約)",
    arguments: [
      "/r/.git/worktrees/od.d-na-me",
      "/r/.git/worktrees/release.v1",
      "/r/.git/worktrees/host:8080",
      "/r/.git/worktrees/...",
    ]
  )
  func dotAndColonNeverAppear(identityPath: String) throws {
    let derived = try name(identityPath)

    #expect(derived.rawValue.contains(".") == false)
    #expect(derived.rawValue.contains(":") == false)
  }

  @Test("`.` を含む名前と `:` を含む名前は同じslugへ潰れる (hashが識別を担う)")
  func dotAndColonCollapseToTheSameSlug() throws {
    #expect(try slug(of: name("/r/.git/worktrees/a.b")) == "a_b")
    #expect(try slug(of: name("/r/.git/worktrees/a:b")) == "a_b")
    #expect(try name("/r/.git/worktrees/a.b") != (try name("/r/.git/worktrees/a:b")))
  }

  @Test("32文字を超えるslugは先頭32文字へ切り詰める")
  func slugIsTruncatedTo32Characters() throws {
    let derived = try name("/r/.git/worktrees/\(String(repeating: "a", count: 40))")

    #expect(try slug(of: derived) == String(repeating: "a", count: 32))
  }

  @Test("ちょうど32文字のslugは切り詰めない")
  func slugOf32CharactersIsKept() throws {
    let basename = String(repeating: "b", count: 32)
    let derived = try name("/r/.git/worktrees/\(basename)")

    #expect(try slug(of: derived) == basename)
  }

  // MARK: - 境界

  @Test("パス要素が1つも無い安定IDでは `worktree` を使う")
  func identityWithoutPathComponentsFallsBack() throws {
    #expect(try name("/").rawValue == "awt-worktree-8a5edab2")
  }

  @Test("`/` 直下の安定IDでも破綻しない")
  func identityAtRootLevel() throws {
    #expect(try name("/x").rawValue == "awt-x-b3d1db31")
  }

  @Test("`_git` の一つ上のパス要素が無ければ `_git` のまま使う")
  func gitWithoutParentComponentKeepsUnderscoreGit() throws {
    #expect(try name("/.git").rawValue == "awt-_git-b8b6a5d3")
  }

  /// `_git` へ正規化される管理ディレクトリは `.git` 以外にもあり得る (worktree 名が `_git` など)。
  /// その場合も同じ分岐に入って一つ上を使う。読みやすさは落ちるが結果は決定的で、識別は hash が担う。
  @Test("`.git` 以外でも正規化結果が `_git` なら一つ上のパス要素を使う")
  func anyUnderscoreGitSlugTakesTheParentComponent() throws {
    #expect(try name("/repo/.git/worktrees/_git").rawValue == "awt-worktrees-4419bcd2")
  }
}
