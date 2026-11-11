import Testing

@testable import TerminalCore

@Suite("§9.1.1 base branch の決定")
struct DiffBaseBranchTests {
  @Test("ユーザーの明示的な選択が自動判定より優先される")
  func prefersUserSelection() {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: .local("release/1.0"), forkPoint: .remote("origin/develop"),
        originHead: .remote("origin/main"))
        == .resolved(branch: .local("release/1.0"), source: .userSelection))
  }

  @Test("選択が無ければ分岐元、次に origin/HEAD を使う")
  func fallsBackInOrder() {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: nil, forkPoint: .remote("origin/develop"),
        originHead: .remote("origin/main"))
        == .resolved(branch: .remote("origin/develop"), source: .forkPoint))
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: nil, forkPoint: nil, originHead: .remote("origin/main"))
        == .resolved(branch: .remote("origin/main"), source: .originHead))
  }

  @Test("分岐元は local branch でも origin/HEAD より優先する")
  func prefersLocalForkPointOverOriginHead() {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: nil, forkPoint: .local("main"), originHead: .remote("origin/main"))
        == .resolved(branch: .local("main"), source: .forkPoint))
  }

  @Test("どれも解決できなければ未決定にする (main へ丸めない)")
  func doesNotFallBackToMain() {
    #expect(
      DiffBaseBranchResolver.resolve(userSelection: nil, forkPoint: nil, originHead: nil)
        == .undetermined)
  }

  @Test(
    "空白だけの値は解決できていないものとして扱う",
    arguments: ["", " ", "\t"])
  func treatsBlankAsAbsent(blank: String) {
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: .local(blank), forkPoint: .local(blank), originHead: .remote(blank))
        == .undetermined)
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: .local(blank), forkPoint: .remote(blank), originHead: .remote("origin/x"))
        == .resolved(branch: .remote("origin/x"), source: .originHead))
    #expect(
      DiffBaseBranchResolver.resolve(
        userSelection: .local(blank), forkPoint: .local("main"), originHead: .remote(blank))
        == .resolved(branch: .local("main"), source: .forkPoint))
  }

  @Test("解決済みの branch 名だけを取り出せる")
  func exposesBranchName() {
    #expect(
      DiffBaseBranch.resolved(branch: .remote("origin/main"), source: .forkPoint).branch
        == .remote("origin/main"))
    #expect(DiffBaseBranch.undetermined.branch == nil)
  }
}

/// `recordedStartPoint` は reflog の `branch: Created from <ref>` の `<ref>`、`resolvedFullName` は
/// それを今の repository で `rev-parse --verify --quiet --symbolic-full-name` した stdout (trim 済み)、
/// `listedBranches` は `for-each-ref refs/heads/ refs/remotes/` の一覧。値は git 2.54.0 の隔離
/// repository での実測 (Issue #829、#842、#894)。
@Suite("§9.1.1 分岐元の採否")
struct DiffForkPointTests {
  // アダプタが渡す一覧と同じく、`HEAD` / `@` / `@{-1}` / `origin/HEAD` の候補の綴りは入れない
  // (`for-each-ref` は `refs/remotes/origin/HEAD` を出すが、`GitBranchRef(fullName:)` が `/HEAD` を
  // 除く)。これらの行は一覧に無いことでも落ちるので、`rev-parse` との照合だけで落ちることは、
  // 一覧に在る `alias` の行で示す。
  private static let listed: [GitBranchRef] = [
    .local("main"), .local("日本語"), .local("feature"), .local("feat"), .local("b8"), .local("alias"),
    .remote("origin/main"), .remote("origin/feature"),
  ]

  @Test(
    "記録どおりの名前で branch に解決できれば分岐元にする",
    arguments: [
      ("origin/main", "refs/remotes/origin/main", GitBranchRef.remote("origin/main")),
      ("refs/remotes/origin/main", "refs/remotes/origin/main", .remote("origin/main")),
      ("refs/heads/main", "refs/heads/main", .local("main")),
      ("main", "refs/heads/main", .local("main")),
      ("日本語", "refs/heads/日本語", .local("日本語")),
    ])
  func adoptsMatchingBranch(recorded: String, resolved: String, expected: GitBranchRef) {
    #expect(
      DiffForkPoint.branch(
        recordedStartPoint: recorded, resolvedFullName: resolved,
        currentBranch: .local("feature"), listedBranches: Self.listed, remoteNames: ["origin"])
        == expected)
  }

  // `HEAD` / `@` / `@{-1}` は記録時ではなく今の文脈で解決されるので、記録と名前が一致しない。
  // `alias` は `refs/heads/main` を指す symbolic ref で、`rev-parse` は指す先の名前を返す (git 2.54.0)。
  @Test(
    "記録と名前が一致しない解決・branch でない解決・自分自身は分岐元にしない",
    arguments: [
      ("HEAD", "refs/heads/main", GitBranchRef.local("feature")),
      ("@", "refs/heads/main", .local("feature")),
      ("@{-1}", "refs/heads/b8", .local("feature")),
      ("origin/HEAD", "refs/remotes/origin/main", .local("feature")),
      ("alias", "refs/heads/main", .local("feature")),
      ("v1", "refs/tags/v1", .local("feature")),
      ("refs/tags/v1", "refs/tags/v1", .local("feature")),
      ("main~0", "", .local("feature")),
      ("main^{commit}", "", .local("feature")),
      ("0123456789abcdef0123456789abcdef01234567", "", .local("feature")),
      ("feat", "refs/heads/feat", .local("feat")),
      ("HEAD", "refs/heads/feature", .local("feature")),
      ("@", "refs/heads/feature", .local("feature")),
    ])
  func rejects(recorded: String, resolved: String, current: GitBranchRef) {
    #expect(
      DiffForkPoint.branch(
        recordedStartPoint: recorded, resolvedFullName: resolved, currentBranch: current,
        listedBranches: Self.listed, remoteNames: ["origin"])
        == nil)
  }

  @Test("同じ短縮名でも local と remote は別の branch として扱う")
  func distinguishesNamespaceFromCurrentBranch() {
    #expect(
      DiffForkPoint.branch(
        recordedStartPoint: "refs/remotes/origin/feature",
        resolvedFullName: "refs/remotes/origin/feature",
        currentBranch: .local("origin/feature"), listedBranches: Self.listed,
        remoteNames: ["origin"])
        == .remote("origin/feature"))
  }

  // 大文字小文字を区別しない volume では、`rev-parse` が一覧に無い綴りの完全名を返す。
  // NFD と NFC の行は `String ==` では等しいので、照合が正準等価に戻ると通ってしまう。
  @Test(
    "一覧に無い綴りの完全名は、近い綴りの branch が在っても分岐元にしない",
    arguments: [
      ("Main", "refs/heads/Main", [GitBranchRef.local("main")]),
      ("origin/Main", "refs/remotes/origin/Main", [.remote("origin/main")]),
      ("\u{304B}\u{3099}", "refs/heads/\u{304B}\u{3099}", [.local("\u{304C}")]),
      ("\u{304C}", "refs/heads/\u{304C}", [.local("\u{304B}\u{3099}")]),
      ("main", "refs/heads/main", []),
    ])
  func rejectsUnlistedSpelling(recorded: String, resolved: String, listed: [GitBranchRef]) {
    #expect(
      DiffForkPoint.branch(
        recordedStartPoint: recorded, resolvedFullName: resolved,
        currentBranch: .local("feature"), listedBranches: listed, remoteNames: ["origin"])
        == nil)
  }

  @Test(
    "一覧にバイト列として在る綴りなら、NFC でも NFD でも分岐元にする",
    arguments: ["\u{304C}", "\u{304B}\u{3099}"])
  func adoptsListedSpelling(name: String) throws {
    let adopted = try #require(
      DiffForkPoint.branch(
        recordedStartPoint: name, resolvedFullName: "refs/heads/" + name,
        currentBranch: .local("feature"),
        listedBranches: [.local("\u{304C}"), .local("\u{304B}\u{3099}")], remoteNames: ["origin"]))
    #expect(Array(adopted.fullName.utf8) == Array(("refs/heads/" + name).utf8))
  }

  // 実行層が `Foundation.Process` だった頃は、記録と一覧が NFC でも argv が NFD へ分解され、`rev-parse` は
  // NFD を返した (git 2.54.0 で計測、Issue #842)。今の実行層は NFC のまま渡す (#875) が、照合は一覧の
  // バイト列で行うので、解決の綴りが違っても一覧の綴りを採る。
  @Test("記録と一覧が NFC なら、解決が NFD でも一覧の NFC の綴りで分岐元にする")
  func adoptsListedSpellingOverDecomposedResolution() {
    let adopted = DiffForkPoint.branch(
      recordedStartPoint: "\u{304C}", resolvedFullName: "refs/heads/\u{304B}\u{3099}",
      currentBranch: .local("feature"), listedBranches: [.local("\u{304C}")],
      remoteNames: ["origin"])
    #expect(adopted == .local("\u{304C}"))
    #expect(adopted.map { Array($0.fullName.utf8) } == Array("refs/heads/\u{304C}".utf8))
  }

  @Test(
    "一覧に別の名前空間の同名 branch しか無ければ分岐元にしない",
    arguments: [
      ("refs/heads/origin/main", GitBranchRef.remote("origin/main")),
      ("refs/remotes/origin/main", .local("origin/main")),
    ])
  func rejectsOtherNamespace(resolved: String, listed: GitBranchRef) {
    #expect(
      DiffForkPoint.branch(
        recordedStartPoint: resolved, resolvedFullName: resolved,
        currentBranch: .local("feature"), listedBranches: [listed], remoteNames: ["origin"])
        == nil)
  }

  @Test(
    "今の branch と同名の remote-tracking ref は分岐元にしない",
    arguments: [
      ("refs/remotes/origin/feature", "origin/feature", "feature", ["origin"]),
      ("origin/feature", "origin/feature", "feature", ["origin"]),
      ("upstream/feature", "upstream/feature", "feature", ["origin", "upstream"]),
      ("up/x/b/feat", "up/x/b/feat", "b/feat", ["up/x"]),
      ("refs/remotes/origin/\u{304B}\u{3099}", "origin/\u{304B}\u{3099}", "\u{304C}", ["origin"]),
    ])
  func rejectsSameNamedRemoteTrackingBranch(
    recorded: String, name: String, current: String, remotes: [String]
  ) {
    let branch = GitBranchRef.remote(name)
    #expect(
      DiffForkPoint.branch(
        recordedStartPoint: recorded, resolvedFullName: branch.fullName,
        currentBranch: .local(current), listedBranches: [branch], remoteNames: remotes)
        == nil)
  }

  @Test(
    "同名の remote-tracking ref 以外は分岐元にする",
    arguments: [
      (GitBranchRef.remote("origin/team/feature"), ["origin"]),
      (.local("origin/feature"), ["origin"]),
      (.remote("foo/feature"), ["origin"]),
      (.remote("origin/feature"), []),
      (.remote("origin/main"), ["origin"]),
    ])
  func adoptsOtherBranches(branch: GitBranchRef, remotes: [String]) {
    #expect(
      DiffForkPoint.branch(
        recordedStartPoint: branch.shortName, resolvedFullName: branch.fullName,
        currentBranch: .local("feature"), listedBranches: [branch], remoteNames: remotes)
        == branch)
  }
}
