import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 実 git に対して §9.1.2 / §9.1.3 / §9.3 の挙動を固定する。fixture では
/// 「4区分がそれぞれ何を含むか」を確かめられないため、隔離 repository を使う。
@Suite("§9 実 git での Diff snapshot 生成")
struct DiffSnapshotBuilderIntegrationTests {
  @Test("commit 済み・staged・unstaged・untracked を分けて持ち、ignored を含めない", .timeLimit(.minutes(1)))
  func separatesOrigins() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("l1\nl2\nl3\n", to: root, "keep.txt")
      try write("ig.txt\n", to: root, ".gitignore")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "base"])
      try await repository.git(["checkout", "-q", "-b", "feature"])

      try write("committed\n", to: root, "committed.txt")
      try await repository.git(["add", "committed.txt"])
      try await repository.git(["commit", "-q", "-m", "feature commit"])
      try write("staged\n", to: root, "staged.txt")
      try await repository.git(["add", "staged.txt"])
      try write("l1\nl2\nCHANGED\n", to: root, "keep.txt")
      try write("untracked\n", to: root, "untracked.txt")
      try write("ignored\n", to: root, "ig.txt")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let result = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      let snapshot = result.snapshot

      #expect(result.patchFailures.isEmpty)
      #expect(result.statusFailures.isEmpty)
      #expect(snapshot.section(.committed)?.files.map(\.path) == ["committed.txt"])
      #expect(snapshot.section(.staged)?.files.map(\.path) == ["staged.txt"])
      #expect(snapshot.section(.unstaged)?.files.map(\.path) == ["keep.txt"])
      #expect(snapshot.section(.untracked)?.files.map(\.path) == ["untracked.txt"])

      let untracked = try #require(snapshot.file(origin: .untracked, path: "untracked.txt"))
      #expect(untracked.hunks.first?.lines.map(\.text) == ["untracked"])
      #expect(untracked.hunks.first?.lines.allSatisfy { $0.kind == .added } == true)
    }
  }

  @Test("同じファイルが2つの出所に出ても hunk をマージしない", .timeLimit(.minutes(1)))
  func keepsSameFileInBothOrigins() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("a\n", to: root, "both.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "base"])
      try write("a\nstaged\n", to: root, "both.txt")
      try await repository.git(["add", "both.txt"])
      try write("a\nstaged\nunstaged\n", to: root, "both.txt")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let snapshot = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      let staged = try #require(snapshot.file(origin: .staged, path: "both.txt"))
      let unstaged = try #require(snapshot.file(origin: .unstaged, path: "both.txt"))
      #expect(staged.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["staged"])
      #expect(
        unstaged.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["unstaged"])
    }
  }

  @Test("base が進んでも merge-base 起点なので base 側の commit は出ない", .timeLimit(.minutes(1)))
  func usesMergeBase() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("x\n", to: root, "x.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "base"])
      try await repository.git(["checkout", "-q", "-b", "feature"])
      try write("feature\n", to: root, "feature.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "feature"])
      try await repository.git(["checkout", "-q", "main"])
      try write("moved on\n", to: root, "main-only.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "main moves"])
      try await repository.git(["checkout", "-q", "feature"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let result = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      #expect(result.snapshot.section(.committed)?.files.map(\.path) == ["feature.txt"])
      if case .base(_, let mergeBase) = result.snapshot.subject {
        #expect(mergeBase.count >= 40)
      } else {
        Issue.record("base subject を期待した")
      }
    }
  }

  @Test("Commit Diff は親との差分。merge commit は第一親を推測しない", .timeLimit(.minutes(1)))
  func commitDiffAndMergeCommit() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("x\n", to: root, "x.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "one"])
      try await repository.git(["checkout", "-q", "-b", "topic"])
      try write("t\n", to: root, "t.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "topic"])
      try await repository.git(["checkout", "-q", "main"])
      try write("m\n", to: root, "m.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "main"])
      try await repository.git(["merge", "-q", "--no-ff", "-m", "merge", "topic"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let commits = try await builder.recentCommits(maxCount: 10)
      let merge = try #require(commits.first { $0.isMerge })
      let single = try #require(commits.first { $0.subject == "one" })
      let root0 = try #require(commits.first { $0.parentHashes.isEmpty })

      await #expect(
        throws: DiffSnapshotBuilderError.unsupportedMergeCommit(
          parents: merge.parentHashes)
      ) {
        try await builder.build(
          .commit(hash: merge.hash, parentHashes: merge.parentHashes),
          id: DiffSnapshotID(rawValue: UUID()), now: Date())
      }

      let snapshot = try await builder.build(
        .commit(hash: single.hash, parentHashes: single.parentHashes),
        id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      #expect(snapshot.sections.map(\.origin) == [.committed])
      #expect(snapshot.section(.committed)?.files.map(\.path) == ["x.txt"])

      // 親を持たない commit も空 tree との差分として出せる。
      let rootSnapshot = try await builder.build(
        .commit(hash: root0.hash, parentHashes: []),
        id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      #expect(rootSnapshot.section(.committed)?.files.isEmpty == true)
    }
  }

  @Test("snapshot は固定され、Refresh は新しい snapshot を作る", .timeLimit(.minutes(1)))
  func snapshotStaysFixedAndRefreshCreatesNewOne() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("a\n", to: root, "a.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "base"])
      try write("a\nb\n", to: root, "a.txt")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let opened = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      let openedLines = opened.file(origin: .unstaged, path: "a.txt")?.hunks.flatMap(\.lines)

      #expect(
        !DiffSnapshotChangeDetection.compare(
          opened: opened.observation, current: try await builder.observe(.base(branch: "main"))
        ).hasChanges)

      try write("a\nb\nc\n", to: root, "a.txt")
      try write("new\n", to: root, "added.txt")
      let comparison = DiffSnapshotChangeDetection.compare(
        opened: opened.observation, current: try await builder.observe(.base(branch: "main")))
      #expect(comparison.hasChanges)
      #expect(comparison.changedPaths.sorted() == ["a.txt", "added.txt"])

      // 開いた snapshot は動かない。
      #expect(opened.file(origin: .unstaged, path: "a.txt")?.hunks.flatMap(\.lines) == openedLines)

      let refreshed = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      #expect(refreshed.id != opened.id)
      #expect(refreshed.section(.untracked)?.files.map(\.path) == ["added.txt"])
    }
  }

  @Test("base branch は upstream、無ければ origin/HEAD、どちらも無ければ未決定", .timeLimit(.minutes(1)))
  func resolvesBaseBranch() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
      #expect(
        await builder.resolveBaseBranch(userSelection: "release/1.0")
          == .resolved(branch: "release/1.0", source: .userSelection))

      let remote = repository.root.appending(path: "remote.git")
      try await repository.git(["init", "-q", "--bare", "-b", "main", remote.path])
      try await repository.git(["remote", "add", "origin", remote.path])
      try await repository.git(["push", "-q", "origin", "main"])
      try await repository.git([
        "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main",
      ])
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: "origin/main", source: .originHead))

      try await repository.git(["checkout", "-q", "-b", "feature"])
      try await repository.git(["push", "-q", "-u", "origin", "feature"])
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: "origin/feature", source: .upstream))
    }
  }

  /// `core.abbrev` は parse した値そのものを変える唯一の config。`--full-index` で pin しないと
  /// 開いた後に config が変わるだけで「変更された」と言う (実測: `=4` で `index 7898..422c`、
  /// `=12` で `index 78981922613b..422c2b7ab3b3`)。
  @Test("core.abbrev を変えても fingerprint は動かない", .timeLimit(.minutes(1)))
  func keepsFingerprintStableAcrossAbbrevConfig() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("a\n", to: root, "f.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "base"])
      try write("a\nb\n", to: root, "f.txt")
      try await repository.git(["add", "f.txt"])

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      try await repository.git(["config", "core.abbrev", "4"])
      let opened = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      try await repository.git(["config", "core.abbrev", "12"])
      let current = try await builder.observe(.base(branch: "main"))

      #expect(
        !DiffSnapshotChangeDetection.compare(opened: opened.observation, current: current)
          .hasChanges)
      #expect(opened.file(origin: .staged, path: "f.txt")?.newObject?.count == 40)
    }
  }

  @Test("Refresh を重ねても旧 snapshot は履歴に残る", .timeLimit(.minutes(1)))
  func keepsOldSnapshotsInHistory() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("a\n", to: root, "a.txt")
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "base"])
      try write("a\nb\n", to: root, "a.txt")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      var history = DiffSnapshotHistory()
      history.append(
        try await builder.build(
          .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
        ).snapshot)
      let openedID = try #require(history.latest?.id)

      try write("a\nb\nc\n", to: root, "a.txt")
      history.append(
        try await builder.build(
          .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
        ).snapshot)

      #expect(history.count == 2)
      #expect(history.latest?.id != openedID)
      let opened = try #require(history.snapshot(openedID))
      // 旧 snapshot は Refresh 後も開いた時点の行のままである (§9.3)。
      #expect(
        opened.file(origin: .unstaged, path: "a.txt")?.hunks.flatMap(\.lines)
          .filter { $0.kind == .added }.map(\.text) == ["b"])
      #expect(
        history.latest?.file(origin: .unstaged, path: "a.txt")?.hunks.flatMap(\.lines)
          .filter { $0.kind == .added }.map(\.text) == ["b", "c"])
    }
  }

  /// 死角を塞ぐのは別 Issue (M4)。ここでは「今は何を検知できないか」を実 git で固定する。
  @Test("畳まれた untracked ディレクトリの中の変更は検知できない", .timeLimit(.minutes(1)))
  func doesNotDetectChangesInsideFoldedUntrackedDirectory() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      // 内部に .git を持つディレクトリは `-uall` でも1件に畳まれる (git 2.50.1 で実測)。
      let nested = root.appending(path: "nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      try await repository.git(["init", "-q", "-b", "main", nested.path])
      try write("x\n", to: nested, "a.txt")
      try write("plain\n", to: root, "plain.txt")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let opened = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot
      #expect(
        opened.file(origin: .untracked, path: "nested/")?.content
          == .unreadable(.notReadable))

      try write("y\n", to: nested, "b.txt")
      try write("z\n", to: nested, "c.txt")
      let afterNested = DiffSnapshotChangeDetection.compare(
        opened: opened.observation, current: try await builder.observe(.base(branch: "main")))
      #expect(afterNested.fileChanges.isEmpty)

      // 読めている untracked ファイルの変更は検知できる。
      try write("plain changed\n", to: root, "plain.txt")
      let afterPlain = DiffSnapshotChangeDetection.compare(
        opened: opened.observation, current: try await builder.observe(.base(branch: "main")))
      #expect(
        afterPlain.fileChanges == [.modified(origin: .untracked, path: "plain.txt")])
    }
  }

  /// Issue #242: 競合中のパスは `git diff` / `git diff --cached` のどちらにも patch 形式では
  /// 現れないため、status の `u` レコードからしか一覧を作れない。
  @Test("競合中のファイルは unmerged 区分に出て、解析失敗にならない", .timeLimit(.minutes(1)))
  func showsUnmergedFiles() async throws {
    try await withGitRepository { repository in
      try await makeConflict(in: repository)
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      let result = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      let snapshot = result.snapshot

      // 主症状の回帰テスト: 汎用の「解析できていません」を出さない。
      #expect(result.patchFailures.isEmpty)
      #expect(result.statusFailures.isEmpty)
      #expect(snapshot.sections.map(\.unparsedRecordCount).allSatisfy { $0 == 0 })

      #expect(snapshot.section(.unmerged)?.files.map(\.path).sorted() == Self.conflictedPaths)
      #expect(snapshot.section(.staged)?.files.map(\.path) == ["auto.txt"])
      #expect(snapshot.section(.unstaged)?.files.map(\.path) == ["auto.txt"])
      for path in Self.conflictedPaths {
        #expect(snapshot.file(origin: .staged, path: path) == nil)
        #expect(snapshot.file(origin: .unstaged, path: path) == nil)
      }

      // 競合はコメント送信の対象外 (§9.2)。本文を持たないので anchor を作れない。
      let line = try #require(DiffLineRange(line: 1))
      #expect(
        snapshot.commentAnchor(
          origin: .unmerged, path: "both.txt", side: .new, lines: line) == nil)
    }
  }

  @Test("競合の XY と stage の OID を保ち、解決すれば staged へ移る", .timeLimit(.minutes(1)))
  func keepsConflictStagesUntilResolved() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try await makeConflict(in: repository)
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      let snapshot = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date()
      ).snapshot

      // OID の値そのものは固定せず、実体の無い stage が nil であることを固定する。
      let both = try #require(conflict(in: snapshot, path: "both.txt"))
      #expect(both.status == WorktreeTrackedFileStatus(index: .unmerged, worktree: .unmerged))
      #expect([both.baseObject, both.ourObject, both.theirObject].allSatisfy { $0 != nil })

      // add/add には共通の祖先が無い。
      let addadd = try #require(conflict(in: snapshot, path: "addadd.txt"))
      #expect(addadd.status == WorktreeTrackedFileStatus(index: .added, worktree: .added))
      #expect(addadd.baseObject == nil)
      #expect([addadd.ourObject, addadd.theirObject].allSatisfy { $0 != nil })

      // modify/delete は ours 側が削除。
      let delmod = try #require(conflict(in: snapshot, path: "delmod.txt"))
      #expect(delmod.status == WorktreeTrackedFileStatus(index: .deleted, worktree: .unmerged))
      #expect(delmod.ourObject == nil)
      #expect([delmod.baseObject, delmod.theirObject].allSatisfy { $0 != nil })

      for path in Self.conflictedPaths { try write("resolved\n", to: root, path) }
      try await repository.git(["add", "-A"])
      let resolved = try await builder.build(
        .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      #expect(resolved.patchFailures.isEmpty)
      #expect(resolved.snapshot.section(.unmerged)?.files.isEmpty == true)
      for path in Self.conflictedPaths {
        #expect(resolved.snapshot.file(origin: .staged, path: path) != nil)
      }
    }
  }

  private static let conflictedPaths = ["addadd.txt", "both.txt", "delmod.txt"]

  /// content / add-add / modify-delete の3種の競合と、自動マージできた `auto.txt` を作る。
  private func makeConflict(in repository: GitTestRepository) async throws {
    let root = repository.mainWorktree
    try write("base\n", to: root, "both.txt")
    try write("base\n", to: root, "delmod.txt")
    try write("x\n", to: root, "auto.txt")
    try await repository.git(["add", "-A"])
    try await repository.git(["commit", "-q", "-m", "base"])

    try await repository.git(["checkout", "-q", "-b", "feature"])
    try write("ours\n", to: root, "both.txt")
    try write("ours\n", to: root, "addadd.txt")
    try FileManager.default.removeItem(at: root.appending(path: "delmod.txt"))
    try await repository.git(["add", "-A"])
    try await repository.git(["commit", "-q", "-m", "feature"])

    try await repository.git(["checkout", "-q", "main"])
    try write("theirs\n", to: root, "both.txt")
    try write("theirs\n", to: root, "addadd.txt")
    try write("base\nmodified\n", to: root, "delmod.txt")
    try write("x\nmain-added\n", to: root, "auto.txt")
    try await repository.git(["add", "-A"])
    try await repository.git(["commit", "-q", "-m", "main"])
    try await repository.git(["checkout", "-q", "feature"])

    // 競合した merge は終了コード 1 で終わる。
    let merge = try await repository.gitExitCode(["merge", "--no-edit", "main"])
    #expect(merge.exitCode == 1)
    try write("x\nmain-added\nunstaged-edit\n", to: root, "auto.txt")
  }

  private func conflict(in snapshot: DiffSnapshot, path: String) -> UnifiedDiffConflict? {
    guard case .conflicted(let conflict) = snapshot.file(origin: .unmerged, path: path)?.content
    else { return nil }
    return conflict
  }

  private func write(_ contents: String, to root: URL, _ name: String) throws {
    try Data(contents.utf8).write(to: root.appending(path: name))
  }
}
