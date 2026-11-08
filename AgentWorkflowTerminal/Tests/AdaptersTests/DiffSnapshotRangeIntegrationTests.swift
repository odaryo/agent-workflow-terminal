import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// §9.1 の範囲表示が読む値を、snapshot を開いた時点で記録していることを実 git で固定する。
@Suite("§9.1 snapshot が記録する範囲")
struct DiffSnapshotRangeIntegrationTests {
  @Test("Base Diff は開いた時点の branch と HEAD を記録する", .timeLimit(.minutes(1)))
  func recordsHeadForBaseDiff() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try await repository.git(["checkout", "-q", "-b", "feature"])
      try write("f\n", to: root, "f.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "feature"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let head = try #require(try await builder.recentCommits(maxCount: 1).first)
      let snapshot = try await builder.build(
        .base(branch: .local("main")), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      #expect(snapshot.head == DiffSnapshotHead(branch: "feature", commit: head.hash))
    }
  }

  @Test("detached HEAD では branch を持たない", .timeLimit(.minutes(1)))
  func recordsDetachedHead() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try await repository.git(["checkout", "-q", "--detach"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let head = try #require(try await builder.recentCommits(maxCount: 1).first)
      let snapshot = try await builder.build(
        .branch(name: .local("main")), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      #expect(snapshot.head == DiffSnapshotHead(branch: nil, commit: head.hash))
    }
  }

  /// Commit Diff の `observation.headObject` は選んだ commit であり、HEAD ではない。
  @Test("Commit Diff でも HEAD を記録し、選んだ commit を HEAD として扱わない", .timeLimit(.minutes(1)))
  func recordsHeadForCommitDiff() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      for name in ["a", "b"] {
        try write("\(name)\n", to: root, "\(name).txt")
        try await repository.git(["add", "-A"])
        try await repository.git(["commit", "-q", "-m", name])
      }

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let commits = try await builder.recentCommits(maxCount: 3)
      let head = try #require(commits.first)
      let older = try #require(commits.first { $0.subject == "a" })
      let snapshot = try await builder.build(
        .commit(hash: older.hash, parentHashes: older.parentHashes),
        id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      #expect(snapshot.head == DiffSnapshotHead(branch: "main", commit: head.hash))
      #expect(snapshot.observation.headObject == older.hash)
    }
  }

  /// `git merge-base` は共通祖先が無いと出力なしの終了コード 1、ref が無いと 128 で終わる
  /// (git 2.50.1 で実測)。前者だけを「merge-base が無い」として区別する。
  @Test("共通祖先の無い branch は merge-base 無しとして失敗する", .timeLimit(.minutes(1)))
  func reportsMissingMergeBase() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try await repository.git(["checkout", "-q", "--orphan", "unrelated"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "orphan"])
      try await repository.git(["checkout", "-q", "main"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      await #expect(throws: DiffSnapshotBuilderError.noMergeBase(branch: "unrelated")) {
        try await builder.build(
          .branch(name: .local("unrelated")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      }
      await #expect(throws: DiffSnapshotBuilderError.noMergeBase(branch: "unrelated")) {
        try await builder.build(
          .base(branch: .local("unrelated")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      }
    }
  }

  @Test("commit の無い branch に居る HEAD は commit 無しとして記録する", .timeLimit(.minutes(1)))
  func recordsUnbornHead() async throws {
    try await withGitRepository { repository in
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      let commit = try #require(try await builder.recentCommits(maxCount: 1).first)
      try await repository.git(["checkout", "-q", "--orphan", "fresh"])

      let snapshot = try await builder.build(
        .commit(hash: commit.hash, parentHashes: commit.parentHashes),
        id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      #expect(snapshot.head == DiffSnapshotHead(branch: "fresh", commit: nil))
    }
  }

  /// shallow の境界より古い共通祖先は見えず、`merge-base` は共通祖先が無いときと同じ
  /// 出力なしの終了コード 1 で終わる (git 2.50.1 / 2.55.0 で実測)。
  @Test("shallow clone では共通祖先が無いと断定しない", .timeLimit(.minutes(1)))
  func doesNotAssertMissingMergeBaseInShallowClone() async throws {
    try await withGitRepository { repository in
      try await commitDivergingBranches(repository)
      // ローカルパスの clone は `--depth` を無視するので file:// で渡す。
      try await repository.git([
        "clone", "-q", "--depth", "1", "--no-single-branch",
        "file://\(repository.mainWorktree.path)", repository.root.appending(path: "shallow").path,
      ])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.root.appending(path: "shallow"),
        processRunner: FoundationProcessRunner())
      await #expect(
        throws: DiffSnapshotBuilderError.mergeBaseUnresolved(
          branch: "origin/feature", reason: .shallowRepository)
      ) {
        try await builder.build(
          .branch(name: .remote("origin/feature")), id: DiffSnapshotID(rawValue: UUID()),
          now: Date())
      }
    }
  }

  @Test("replace で親を切った履歴では共通祖先が無いと断定しない", .timeLimit(.minutes(1)))
  func doesNotAssertMissingMergeBaseWithReplaceGraft() async throws {
    try await withGitRepository { repository in
      try await commitDivergingBranches(repository)
      try await repository.git(["replace", "--graft", "feature"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      await #expect(
        throws: DiffSnapshotBuilderError.mergeBaseUnresolved(
          branch: "feature", reason: .rewrittenHistory)
      ) {
        try await builder.build(
          .branch(name: .local("feature")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      }
    }
  }

  /// `info/grafts` は stderr に非推奨の hint を出すが、`advice.graftFileDeprecated=false` で
  /// 消える (git 2.50.1 / 2.55.0 で実測)。stderr ではなくファイルの有無で見ることを固定する。
  @Test("info/grafts で親を切った履歴では共通祖先が無いと断定しない", .timeLimit(.minutes(1)))
  func doesNotAssertMissingMergeBaseWithGraftFile() async throws {
    try await withGitRepository { repository in
      try await commitDivergingBranches(repository)
      try await repository.git(["config", "advice.graftFileDeprecated", "false"])
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      try await repository.git(["checkout", "-q", "feature"])
      let feature = try #require(try await builder.recentCommits(maxCount: 1).first)
      try await repository.git(["checkout", "-q", "main"])
      let info = repository.mainWorktree.appending(path: ".git/info")
      try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
      try write("\(feature.hash)\n", to: info, "grafts")

      await #expect(
        throws: DiffSnapshotBuilderError.mergeBaseUnresolved(
          branch: "feature", reason: .rewrittenHistory)
      ) {
        try await builder.build(
          .branch(name: .local("feature")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      }
    }
  }

  /// 短縮名では共通祖先の無い tag が選ばれるため、branch の完全名で期待値を求める。
  @Test("同名 tag に共通祖先が無くても local branch の snapshot を作る", .timeLimit(.minutes(1)))
  func usesBranchWhenSameNamedTagHasUnrelatedHistory() async throws {
    try await withGitRepository { repository in
      try await repository.git(["checkout", "-q", "--orphan", "unrelated"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "orphan"])
      try await repository.git(["tag", "ambiguous"])
      try await repository.git(["checkout", "-q", "main"])
      try await repository.git(["branch", "ambiguous"])
      let expected = try await mergeBase("refs/heads/ambiguous", in: repository)

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      let snapshot = try await builder.build(
        .branch(name: .local("ambiguous")), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      #expect(snapshot.subject == .branch(name: .local("ambiguous"), mergeBase: expected))
    }
  }

  @Test("存在しない ref は merge-base 無しへ丸めない", .timeLimit(.minutes(1)))
  func keepsUnknownRefAsGitFailure() async throws {
    try await withGitRepository { repository in
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      do {
        _ = try await builder.build(
          .branch(name: .local("no-such-branch")), id: DiffSnapshotID(rawValue: UUID()), now: Date()
        )
        Issue.record("存在しない ref で snapshot が作られた")
      } catch let error as DiffSnapshotBuilderError {
        guard case .git(.commandFailed(let exitCode, _, _)) = error else {
          Issue.record("想定外のエラー: \(error)")
          return
        }
        #expect(exitCode == 128)
      }
    }
  }

  @Test("同名 tag があっても local branch の merge-base を記録する", .timeLimit(.minutes(1)))
  func usesBranchInsteadOfTag() async throws {
    try await withGitRepository { repository in
      try await repository.git(["tag", "feature"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "branch base"])
      try await repository.git(["branch", "feature"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "head"])
      let expected = try await mergeBase("refs/heads/feature", in: repository)
      let tagBase = try await mergeBase("refs/tags/feature", in: repository)
      try #require(expected != tagBase)

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      let snapshot = try await builder.build(
        .base(branch: .local("feature")), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      #expect(snapshot.subject == .base(branch: .local("feature"), mergeBase: expected))
    }
  }

  @Test("同じ短縮名の local と remote を選び分ける", .timeLimit(.minutes(1)))
  func distinguishesLocalAndRemoteMergeBases() async throws {
    try await withGitRepository { repository in
      try await repository.git(["update-ref", "refs/remotes/origin/feature", "HEAD"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "local base"])
      try await repository.git(["branch", "origin/feature"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "head"])
      let remoteBase = try await mergeBase("refs/remotes/origin/feature", in: repository)
      let localBase = try await mergeBase("refs/heads/origin/feature", in: repository)
      try #require(remoteBase != localBase)

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      let remote = try await builder.build(
        .branch(name: .remote("origin/feature")), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      let local = try await builder.build(
        .branch(name: .local("origin/feature")), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      #expect(remote.subject == .branch(name: .remote("origin/feature"), mergeBase: remoteBase))
      #expect(local.subject == .branch(name: .local("origin/feature"), mergeBase: localBase))
    }
  }

  @Test(
    "upstream の local と remote の名前空間を保持する", .timeLimit(.minutes(1)),
    arguments: [GitBranchRef.local("local-base"), .remote("origin/main")])
  func resolvesTypedUpstream(upstream: GitBranchRef) async throws {
    try await withGitRepository { repository in
      switch upstream {
      case .local(let name):
        try await repository.git(["branch", name])
      case .remote:
        try await repository.git([
          "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
        ])
        try await repository.git(["update-ref", upstream.fullName, "HEAD"])
      }
      try await repository.git(["branch", "--set-upstream-to=" + upstream.shortName])
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: upstream, source: .upstream))

      try await repository.git(["update-ref", "-d", upstream.fullName])
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test("detached HEAD では元の branch の upstream を使わない", .timeLimit(.minutes(1)))
  func doesNotResolveUpstreamForDetachedHead() async throws {
    try await withGitRepository { repository in
      try await repository.git(["branch", "local-base"])
      try await repository.git(["branch", "--set-upstream-to=local-base"])
      try await repository.git(["checkout", "-q", "--detach"])
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  private func mergeBase(
    _ fullName: String, in repository: GitTestRepository
  ) async throws -> String {
    let result = try await repository.gitExitCode(["merge-base", fullName, "HEAD"])
    try #require(result.exitCode == 0)
    let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    try #require(!oid.isEmpty)
    return oid
  }

  /// main と feature が init から分かれた repository。共通祖先は init。
  private func commitDivergingBranches(_ repository: GitTestRepository) async throws {
    let root = repository.mainWorktree
    try await repository.git(["checkout", "-q", "-b", "feature"])
    try write("feature\n", to: root, "feature.txt")
    try await repository.git(["add", "-A"])
    try await repository.git(["commit", "-q", "-m", "feature"])
    try await repository.git(["checkout", "-q", "main"])
    try write("main\n", to: root, "main.txt")
    try await repository.git(["add", "-A"])
    try await repository.git(["commit", "-q", "-m", "main"])
  }

  private func write(_ contents: String, to root: URL, _ name: String) throws {
    try Data(contents.utf8).write(to: root.appending(path: name))
  }
}
