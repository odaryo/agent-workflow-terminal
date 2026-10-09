import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§9.1 Diff の範囲表示")
struct DiffRangeSummaryTests {
  private let mergeBase = "0123456789abcdef0123456789abcdef01234567"
  private let head = "fedcba9876543210fedcba9876543210fedcba98"

  @Test("Base Diff は対象・決めた経路・merge-base 起点・出所ごとの件数を出す")
  func describesBaseDiff() {
    let snapshot = snapshot(
      subject: .base(branch: "origin/main", mergeBase: mergeBase),
      head: DiffSnapshotHead(branch: "feat/x", object: head),
      counts: [.committed: 2, .staged: 1, .unstaged: 3, .untracked: 1])
    let summary = DiffRangeSummary(
      snapshot: snapshot,
      context: DiffSnapshotRangeContext(
        worktreeName: "feat/x", baseSource: .upstream, commit: nil))

    #expect(summary.target == "feat/x — branch feat/x @ fedcba9")
    #expect(summary.comparison == "base origin/main (upstream で決定)")
    #expect(summary.origin == "merge-base 0123456 起点")
    #expect(
      summary.contents
        == "commit済み 2・staged 1・unstaged 3・untracked 1・競合 0 (ignored は含まない)")
  }

  @Test(
    "base を決めた経路を区別する",
    arguments: [
      (DiffBaseBranchSource.upstream, "base main (upstream で決定)"),
      (.originHead, "base main (origin/HEAD で決定)"),
      (.userSelection, "base main (ユーザーが選択)"),
    ])
  func distinguishesBaseSource(source: DiffBaseBranchSource, expected: String) {
    let summary = DiffRangeSummary(
      snapshot: snapshot(subject: .base(branch: "main", mergeBase: mergeBase), head: nil),
      context: DiffSnapshotRangeContext(worktreeName: "t", baseSource: source, commit: nil))
    #expect(summary.comparison == expected)
  }

  @Test("Branch Diff は選んだ branch と merge-base を出し、detached を明示する")
  func describesBranchDiffOnDetachedHead() {
    let summary = DiffRangeSummary(
      snapshot: snapshot(
        subject: .branch(name: "feat/other", mergeBase: mergeBase),
        head: DiffSnapshotHead(branch: nil, object: head)),
      context: DiffSnapshotRangeContext(
        worktreeName: "Project Root", baseSource: nil, commit: nil))

    #expect(summary.target == "Project Root — detached @ fedcba9")
    #expect(summary.comparison == "branch feat/other")
    #expect(summary.origin == "merge-base 0123456 起点")
  }

  @Test("HEAD を観測できなかったことを黙って空にしない")
  func statesUnobservedHead() {
    let summary = DiffRangeSummary(
      snapshot: snapshot(subject: .branch(name: "b", mergeBase: mergeBase), head: nil),
      context: DiffSnapshotRangeContext(worktreeName: "t", baseSource: nil, commit: nil))
    #expect(summary.target == "t — HEAD を観測できませんでした")
  }

  @Test("Commit Diff は親との差分で、未commit 変更を含まないと示す")
  func describesCommitDiff() {
    let summary = DiffRangeSummary(
      snapshot: snapshot(
        subject: .commit(hash: head), head: DiffSnapshotHead(branch: "main", object: mergeBase),
        counts: [.committed: 4]),
      context: DiffSnapshotRangeContext(
        worktreeName: "main", baseSource: nil,
        commit: DiffCommitLabel(abbreviatedHash: "fedcba98", subject: "fix: x", parentCount: 1)))

    #expect(summary.target == "main — branch main @ 0123456")
    #expect(summary.comparison == "commit fedcba98 fix: x")
    #expect(summary.origin == "その commit の親")
    #expect(summary.contents == "その commit と親の差分 4 ファイル。未commit 変更は含まない")
  }

  @Test("親の無い commit は空 tree との差分であることを示す")
  func describesRootCommit() {
    let summary = DiffRangeSummary(
      snapshot: snapshot(subject: .commit(hash: head), head: nil, counts: [.committed: 1]),
      context: DiffSnapshotRangeContext(
        worktreeName: "main", baseSource: nil,
        commit: DiffCommitLabel(abbreviatedHash: "fedcba9", subject: "init", parentCount: 0)))
    #expect(summary.origin == "親の無い commit (空 tree)")
  }

  private func snapshot(
    subject: DiffSubject, head: DiffSnapshotHead?, counts: [DiffChangeOrigin: Int] = [:]
  ) -> DiffSnapshot {
    DiffSnapshot(
      id: DiffSnapshotID(rawValue: UUID()),
      subject: subject,
      createdAt: Date(timeIntervalSince1970: 0),
      sections: DiffChangeOrigin.allCases.map { origin in
        DiffOriginSection(
          origin: origin,
          files: (0..<(counts[origin] ?? 0)).map { index in
            UnifiedDiffFile(
              oldPath: "\(origin)-\(index)", newPath: "\(origin)-\(index)",
              changeKind: .modified, content: .noContentChange)
          })
      },
      observation: DiffSnapshotObservation(headObject: nil, files: []),
      head: head)
  }
}

@Suite("§9.1 比較先の候補")
struct DiffComparisonCandidatesTests {
  private let refs = GitRefNameList.parse(
    output: [
      "refs/heads/main", "refs/heads/feat/a", "refs/heads/feat/b", "refs/heads/spike",
      "refs/remotes/origin/main", "refs/remotes/origin/feat/a",
    ].joined(separator: "\n"))
  private let tasks = [
    DiffComparisonTask(name: "feat/a", branch: "feat/a", directory: "wt-a"),
    DiffComparisonTask(name: "review-tab", branch: "feat/b", directory: "wt-b"),
  ]

  @Test("他のタスクの branch を先頭に置き、local には重ねて出さない")
  func putsOtherTasksFirst() {
    let candidates = DiffComparisonCandidates(tasks: tasks, refNames: refs, query: "")
    #expect(candidates.tasks == tasks)
    #expect(candidates.localBranches == ["main", "spike"])
    #expect(candidates.remoteBranches == ["origin/main", "origin/feat/a"])
  }

  @Test("検索は branch 名・タスク名・ディレクトリ名の部分一致で、大文字小文字を区別しない")
  func filtersByQuery() {
    let byTask = DiffComparisonCandidates(tasks: tasks, refNames: refs, query: "REVIEW")
    #expect(byTask.tasks.map(\.branch) == ["feat/b"])
    #expect(byTask.localBranches.isEmpty)
    #expect(byTask.remoteBranches.isEmpty)

    let byBranch = DiffComparisonCandidates(tasks: tasks, refNames: refs, query: " main ")
    #expect(byBranch.tasks.isEmpty)
    #expect(byBranch.localBranches == ["main"])
    #expect(byBranch.remoteBranches == ["origin/main"])
    #expect(!byBranch.isEmpty)

    let byDirectory = DiffComparisonCandidates(tasks: tasks, refNames: refs, query: "wt-a")
    #expect(byDirectory.tasks.map(\.branch) == ["feat/a"])

    #expect(DiffComparisonCandidates(tasks: tasks, refNames: refs, query: "zzz").isEmpty)
  }

  @Test("ref 一覧を読めていなくても他のタスクの branch は選べる")
  func keepsTasksWithoutRefNames() {
    let candidates = DiffComparisonCandidates(tasks: tasks, refNames: nil, query: "")
    #expect(candidates.tasks == tasks)
    #expect(candidates.localBranches.isEmpty)
  }
}

@Suite("§9.1 Diff の対象 worktree")
struct DiffWorktreeContextTests {
  @Test("同じ Project の他の Active worktree の branch だけを候補にする")
  func listsOtherActiveTasks() throws {
    let worktrees = [
      try task("/p/wt/a", branch: "feat/a", .active),
      try task("/p/wt/b", branch: "feat/b", .active),
      try task("/p/wt/c", branch: "feat/c", .inactive),
      try task("/p/wt/d", branch: nil, .active),
    ]
    let context = DiffWorktreeContext(
      worktreeRoot: URL(fileURLWithPath: "/p/wt/a"), projectRoot: try projectRoot(),
      worktrees: worktrees)

    #expect(context.displayName == "feat/a")
    #expect(
      context.otherTasks == [DiffComparisonTask(name: "feat/b", branch: "feat/b", directory: "b")])
  }

  @Test("Project Root は「Project Root」と表示し、すべての Active task を候補にする")
  func namesProjectRoot() throws {
    let context = DiffWorktreeContext(
      worktreeRoot: URL(fileURLWithPath: "/p/repo"), projectRoot: try projectRoot(),
      worktrees: [try task("/p/wt/a", branch: "feat/a", .active)])

    #expect(context.displayName == "Project Root")
    #expect(context.otherTasks.map(\.branch) == ["feat/a"])
  }

  @Test("一覧に無い worktree はディレクトリ名で表示する")
  func fallsBackToDirectoryName() throws {
    let context = DiffWorktreeContext(
      worktreeRoot: URL(fileURLWithPath: "/p/wt/gone"), projectRoot: try projectRoot(),
      worktrees: [])
    #expect(context.displayName == "gone")
  }

  private func projectRoot() throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/p/repo")), worktreePath: "/p/repo",
      branch: "main", isProjectRoot: true)
  }

  private func task(
    _ path: String, branch: String?, _ activation: WorktreeActivation
  ) throws -> TaskWorktree {
    TaskWorktree(
      detected: DetectedWorktree(
        identity: try #require(WorktreeIdentity(rawValue: path)), worktreePath: path,
        branch: branch, isProjectRoot: false),
      activation: activation)
  }
}
