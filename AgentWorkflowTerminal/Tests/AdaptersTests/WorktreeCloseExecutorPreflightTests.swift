import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 実行直前の読み直し (設計書 §3.4、Issue #354)。中止したときは tmux にも git の書き込みにも
/// 1回も触れていないことまで確かめる —— session 終了も worktree 削除も巻き戻せない。
@Suite("Close の実行直前の読み直し (設計書 §3.4)")
struct WorktreeCloseExecutorPreflightTests {
  private static let administrativeDirectory = "/repo/.git/worktrees/feature-a"

  private struct Mismatch {
    let git: WorktreeCloseGitStub
    let existingFiles: Set<String>
    let expected: WorktreeClosePreflightRefusal

    init(
      _ git: WorktreeCloseGitStub, _ existingFiles: Set<String>,
      _ expected: WorktreeClosePreflightRefusal
    ) {
      self.git = git
      self.existingFiles = existingFiles
      self.expected = expected
    }
  }

  private static let mismatches: [Mismatch] = [
    Mismatch(gitStub(head: gitNotFound), [], .detachedHead),
    Mismatch(
      gitStub(head: headOnBranch("other")), [], .branchChanged(planned: "topic", current: "other")),
    Mismatch(gitStub(references: ["MERGE_HEAD": gitSuccess]), [], .operationInProgress([.merge])),
    Mismatch(
      gitStub(), ["\(administrativeDirectory)/rebase-merge"], .operationInProgress([.rebase])),
    Mismatch(gitStub(), ["\(administrativeDirectory)/BISECT_LOG"], .operationInProgress([.bisect])),
  ]

  @Test("HEAD・途中状態が計画時と食い違えば、何も撃たずに中止する", arguments: 0..<mismatches.count)
  func abandonsWithoutTouchingTmuxOrWritingGit(index: Int) async throws {
    let mismatch = Self.mismatches[index]
    let harness = try WorktreeCloseHarness(git: mismatch.git, existingFiles: mismatch.existingFiles)

    let execution = try await harness.executor.execute(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), uncommitted: .present,
        merge: try merged(.squash), continuation: .forcingAcknowledgedWarnings))

    #expect(execution == .abandoned(mismatch.expected))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  /// 読み直せないことは「食い違いが無い」証拠にならない。git 2.50.1 実測: 管理ディレクトリが
  /// 無いと `-C` が rc=128 / `fatal: cannot change to '<path>': No such file or directory`。
  @Test("読み直しに失敗したら、実行しない側へ倒す")
  func abandonsWhenTheRereadFails() async throws {
    let failure = ProcessRunResult(
      exitCode: 128, stdout: "",
      stderr: "fatal: cannot change to '\(Self.administrativeDirectory)': No such file\n")
    for git in [gitStub(head: failure), gitStub(references: ["REVERT_HEAD": failure])] {
      let harness = try WorktreeCloseHarness(git: git)

      let execution = try await harness.executor.execute(
        try harness.plan(.terminateSession(.keepWorktree)))

      #expect(
        execution
          == .abandoned(
            .observationFailed(
              .git(.commandFailed(exitCode: 128, stdout: "", stderr: failure.stderr)))))
      #expect(await harness.tmux.invocations.isEmpty)
    }
  }

  /// `repositoryDirectory` (`/repo`) で `symbolic-ref HEAD` を撃つと、答えるのは Project Root の
  /// HEAD である。対象の管理ディレクトリで撃っていることを argv で固定する。
  @Test("読み直しは対象の管理ディレクトリで撃ち、通れば計画どおり実行する")
  func rereadsInTheAdministrativeDirectoryAndThenExecutes() async throws {
    let harness = try WorktreeCloseHarness()

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), merge: try merged(.squash)))

    #expect(outcome.failure == nil)
    let prefix = ["--no-optional-locks", "-C", Self.administrativeDirectory, "--no-pager"]
    #expect(
      await harness.git.preflightInvocations.map(\.arguments) == [
        prefix + ["symbolic-ref", "--quiet", "HEAD"],
        prefix + ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"],
        prefix + ["rev-parse", "--verify", "--quiet", "CHERRY_PICK_HEAD"],
        prefix + ["rev-parse", "--verify", "--quiet", "REVERT_HEAD"],
        prefix + ["rev-parse", "--verify", "--quiet", "refs/heads/topic"],
      ])
  }

  /// `branch -D` は未マージの commit も消す。判定の後に積まれた commit はマージ済みと
  /// 確かめられていない (Issue #359)。
  @Test("branch の先端が判定時から動いていたら、何も撃たずに中止する")
  func abandonsWhenTheBranchTipMoved() async throws {
    let moved = String(repeating: "b", count: 40)
    let harness = try WorktreeCloseHarness(git: gitStub(tip: tipOutput(moved)))

    let execution = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: merged(.squash)))

    #expect(
      execution
        == .abandoned(
          .branchTipMoved(
            planned: try inspectedTip(), current: try #require(CommitObjectID(moved)))))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  @Test(
    "先端を読めなければ、動いていないと見なさず中止する",
    arguments: [
      (
        ProcessRunResult(exitCode: 1, stdout: "", stderr: ""),
        GitWorktreeProgressReadError.git(.commandFailed(exitCode: 1, stdout: "", stderr: ""))
      ),
      (
        ProcessRunResult(exitCode: 0, stdout: "abc\n", stderr: ""),
        .unexpectedTipOutput("abc\n")
      ),
    ])
  func abandonsWhenTheTipCannotBeRead(
    result: ProcessRunResult, expected: GitWorktreeProgressReadError
  ) async throws {
    let harness = try WorktreeCloseHarness(git: gitStub(tip: result))

    let execution = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: merged(.squash)))

    #expect(execution == .abandoned(.observationFailed(expected)))
    #expect(await harness.tmux.invocations.isEmpty)
  }

  /// 先端の照合は `-D` の巻き込みを止めるためのもので、branch を残す計画では問わない。
  @Test("branch を消さない計画では、先端が動いていても照合しない")
  func doesNotCompareTheTipWithoutBranchDeletion() async throws {
    let harness = try WorktreeCloseHarness(
      git: gitStub(tip: tipOutput(String(repeating: "b", count: 40))))

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch)), merge: merged(.squash)))

    #expect(outcome.failure == nil)
    #expect(
      await harness.git.preflightInvocations.contains { $0.arguments.last == "refs/heads/topic" }
        == false)
  }

  @Test("空の計画では読み直さない")
  func doesNotRereadForAnEmptyPlan() async throws {
    let harness = try WorktreeCloseHarness(git: gitStub(head: gitNotFound))

    let execution = try await harness.executor.execute(try harness.plan(.hideFromUI))

    #expect(execution == .executed(WorktreeCloseOutcome(completed: [], failure: nil, skipped: [])))
    #expect(await harness.git.invocations.isEmpty)
  }

  /// `String` の `==` は正準等価な別表記を等しいと答える (実測: `"caf\u{00E9}" == "cafe\u{0301}"`
  /// は `true`)。git にとっては別の branch である。
  @Test("branch 名はバイト列で比べる")
  func comparesBranchNamesByteWise() async throws {
    let planned = try WorktreeCloseHarness.detected(branch: "caf\u{00E9}")
    let harness = try WorktreeCloseHarness(git: gitStub(head: headOnBranch("cafe\u{0301}")))

    let execution = try await harness.executor.execute(
      try harness.plan(.terminateSession(.keepWorktree), worktree: planned))

    #expect(
      execution == .abandoned(.branchChanged(planned: "caf\u{00E9}", current: "cafe\u{0301}")))
  }
}
