import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("Close の後始末の実行 (設計書 §3.4)")
struct WorktreeCloseExecutorTests {
  @Test("Close 専用の書き込み command は2種類しか作れない")
  func writeCommandBuildsOnlyTheTwoCleanupCommands() {
    #expect(
      GitCloseWriteCommand.removeWorktree(path: "/repo/wt", force: false)?.arguments
        == ["worktree", "remove", "--", "/repo/wt"])
    #expect(
      GitCloseWriteCommand.removeWorktree(path: "/repo/wt", force: true)?.arguments
        == ["worktree", "remove", "--force", "--", "/repo/wt"])
    #expect(
      GitCloseWriteCommand.deleteMergedBranch(name: "topic")?.arguments
        == ["branch", "--delete", "--force", "--", "topic"])
    // `-` 始まりの値も `--` の後ろに置かれるので option としては解釈されない。
    #expect(
      GitCloseWriteCommand.deleteMergedBranch(name: "-D")?.arguments
        == ["branch", "--delete", "--force", "--", "-D"])
  }

  @Test("絶対パスでない作業ツリーは command にしない", arguments: ["wt", "", "../wt"])
  func writeCommandRejectsNonAbsoluteWorktreePath(path: String) {
    #expect(GitCloseWriteCommand.removeWorktree(path: path, force: false) == nil)
    #expect(GitCloseWriteCommand.removeWorktree(path: path, force: true) == nil)
  }

  @Test(
    "短縮 local branch 名でない値は command にしない",
    arguments: ["", "refs/heads/topic", "refs/foo/bar"])
  func writeCommandRejectsNonShortBranchName(name: String) {
    #expect(GitCloseWriteCommand.deleteMergedBranch(name: name) == nil)
  }

  @Test("空の計画では tmux も git も撃たない")
  func executesNothingForEmptyPlan() async throws {
    let harness = try WorktreeCloseHarness()

    let outcome = try await harness.run(try harness.plan(.hideFromUI))

    #expect(outcome == WorktreeCloseOutcome(completed: [], failure: nil, skipped: []))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.invocations.isEmpty)
  }

  @Test("session 終了・worktree 削除・branch 削除をこの順に撃つ")
  func executesStepsInOrder() async throws {
    let harness = try WorktreeCloseHarness()

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), merge: try merged(.squash)))

    #expect(
      outcome.completed == [
        .terminateSession, .removeWorktree(force: false),
        .deleteBranch(name: "topic", tip: try inspectedTip()),
      ])
    #expect(outcome.failure == nil)
    #expect(outcome.skipped.isEmpty)
    #expect(
      await harness.git.repositoryInvocations.map(\.arguments) == [
        gitArgv("worktree", "remove", "--", "/repo/wt"),
        gitArgv("branch", "--delete", "--force", "--", "topic"),
      ])
  }

  /// session 名を別引数で渡せると A の Close で B の session を殺せる (`init` の doc コメント)。
  /// その経路は `session:` を落として型で閉じたので、ここでは導出元が対象の安定 ID であることを
  /// 守る。期待値に `TmuxSessionName` を呼ばないのは、同じ導出をテスト側でも書くと導出元を
  /// 取り違える変異が素通りするため。値は §3.5 の規則から手元で計算して確かめた。
  @Test(
    "終了する session 名は対象 worktree の安定 ID から導出する",
    arguments: [
      ("/repo/.git/worktrees/feature-a", "awt-feature-a-219261c3"),
      ("/repo/.git/worktrees/feature-b", "awt-feature-b-e7b88064"),
    ])
  func derivesTheSessionNameFromTheTargetWorktree(
    identity: String, expectedSessionName: String
  ) async throws {
    let harness = try WorktreeCloseHarness(identity: identity)

    _ = try await harness.run(try harness.plan(.terminateSession(.keepWorktree)))

    #expect(
      await harness.tmux.invocations.map(\.arguments) == [
        ["-u", "-L", "awt-test", "kill-session", "-t", "=\(expectedSessionName)"]
      ])
  }

  @Test("承知のうえでの続行では worktree remove に --force が付く")
  func passesForceWhenConfirmed() async throws {
    let harness = try WorktreeCloseHarness()

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.keepBranch)), uncommitted: .present,
        continuation: .forcingAcknowledgedWarnings))

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: true)])
    #expect(
      await harness.git.repositoryInvocations.map(\.arguments)
        == [gitArgv("worktree", "remove", "--force", "--", "/repo/wt")])
  }

  @Test("session がもう無いことと server が動いていないことは Close の成功")
  func treatsAbsentSessionAndStoppedServerAsSuccess() async throws {
    for stderr in ["can't find session: awt-feature-a-219261c3\n"] + tmuxServerAbsentStderrs {
      let harness = try WorktreeCloseHarness(tmux: .init(result: stubFailure(stderr: stderr)))

      let outcome = try await harness.run(
        try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

      #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
      #expect(outcome.failure == nil)
    }
  }

  @Test("分類できない tmux の失敗では worktree を消さない", arguments: tmuxNotServerAbsentStderrs)
  func stopsBeforeRemovalWhenSessionTerminationFails(stderr: String) async throws {
    let harness = try WorktreeCloseHarness(tmux: .init(result: stubFailure(stderr: stderr)))

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), merge: try merged(.squash)))

    #expect(outcome.completed.isEmpty)
    #expect(outcome.failure?.step == .terminateSession)
    #expect(
      outcome.failure?.reason
        == .tmux(.tmux(.commandFailed(exitCode: 1, stdout: "", stderr: stderr))))
    #expect(
      outcome.skipped == [
        .removeWorktree(force: false), .deleteBranch(name: "topic", tip: try inspectedTip()),
      ])
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  @Test("worktree remove が拒否されたら branch は消さない")
  func stopsBeforeBranchDeletionWhenRemovalIsRefused() async throws {
    let harness = try WorktreeCloseHarness(git: refusedRemovalGitStub())

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), merge: try merged(.squash)))

    #expect(outcome.completed == [.terminateSession])
    #expect(outcome.failure?.step == .removeWorktree(force: false))
    #expect(outcome.skipped == [.deleteBranch(name: "topic", tip: try inspectedTip())])
    #expect(!(await harness.git.arguments.contains { $0.contains("branch") }))
  }

  /// git が実行を拒否した場合。git 2.50.1 実測 (`mktemp -d` 配下の使い捨て repository): 未commit
  /// 変更のある worktree への `worktree remove --` は rc=128 /
  /// `fatal: '<path>' contains modified or untracked files, use --force to delete it` で、
  /// 直後の list にはその worktree が `prunable` の付かない素の record のまま残っていた。
  @Test("実行を拒否された worktree remove は「登録が残っている」として返す")
  func reportsRetainedRegistrationWhenRemovalIsRefused() async throws {
    let harness = try WorktreeCloseHarness(git: refusedRemovalGitStub())

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(
      outcome.failure?.reason
        == .worktreeRemoval(
          .commandFailed(exitCode: 128, stdout: "", stderr: removalRefusedStderr),
          registration: .retained))
    #expect(
      await harness.git.arguments.last == gitArgv("worktree", "list", "--porcelain", "-z"))
  }

  /// **record が残っていることは「やり直せる」を意味しない。** git 2.50.1 実測 (`mktemp -d` 配下、
  /// 後始末で `chmod -R u+rwX`): 管理ディレクトリ `.git/worktrees/p6` を `chmod 500` にすると
  /// `worktree remove --` は rc=255 / `error: failed to delete '<管理ディレクトリ>': Permission
  /// denied` で終わり、**作業ツリーは完全に消える**のに list には `prunable` 付きの record が残る。
  /// 一覧段が落とす条件は `prunable` と bare の2つで、答えは同じである。生の `-z` 出力を `cat -v`
  /// で写した (`^@` が `\0`)。`worktree <path>^@HEAD <oid>^@branch refs/heads/p6^@prunable gitdir
  /// file points to non-existent location^@^@` に対し、**bare な record は HEAD も branch も持たず**
  /// `worktree <path>^@bare^@^@` だった。
  @Test(
    "prunable / bare な record は「残っているが scan に載らない」として返す",
    arguments: [listedTargetAttributes + [prunableAttribute], ["bare"]])
  func reportsRetainedButNotScannableWhenTheRecordIsPrunable(attributes: [String]) async throws {
    let stderr = "error: failed to delete '.git/worktrees/wt': Permission denied\n"
    let listed = worktreeListOutput(targetAttributes: attributes)
    let harness = try WorktreeCloseHarness(
      git: gitStub(
        removeWorktree: .init(exitCode: 255, stdout: "", stderr: stderr),
        worktreeList: .init(exitCode: 0, stdout: listed, stderr: "")))

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), merge: try merged(.squash)))

    #expect(outcome.completed == [.terminateSession])
    #expect(
      outcome.failure?.reason
        == .worktreeRemoval(
          .commandFailed(exitCode: 255, stdout: "", stderr: stderr),
          registration: .retainedButNotScannable))
    #expect(outcome.skipped == [.deleteBranch(name: "topic", tip: try inspectedTip())])
  }

  /// 1件目 —— **`worktree remove` は step として atomic ではない。** git 2.50.1 実測: clean な
  /// worktree の**サブディレクトリ**を `chmod 500` にすると上と同じ rc=255 になるが、今度は list
  /// からその worktree が消え、`.git/worktrees/` ごと削除されていた (作業ツリーは中途半端に残る)。
  ///
  /// 2件目・3件目 —— 突き合わせは UTF-8 バイト列で行う。実測:
  /// `"/repo/caf\u{00E9}" == "/repo/cafe\u{0301}"` は `true` (正準等価)、
  /// `"/repo/WT".lowercased() == "/repo/wt".lowercased()` も `true`。どちらの誤りも向きは
  /// **偽 `.retained`** —— 消えた登録を「残っている」と読ませる。
  @Test(
    "list に対象のパスが見えなければ「登録が消えた」として返す",
    arguments: [
      (nil, "/repo/wt"), ("/repo/caf\u{00E9}", "/repo/cafe\u{0301}"), ("/repo/WT", "/repo/wt"),
    ])
  func reportsDroppedRegistrationWhenThePathIsNotListed(
    listedPath: String?, targetPath: String
  ) async throws {
    let stderr = "error: failed to delete '\(targetPath)': Permission denied\n"
    let harness = try WorktreeCloseHarness(
      git: gitStub(
        removeWorktree: .init(exitCode: 255, stdout: "", stderr: stderr),
        worktreeList: .init(
          exitCode: 0, stdout: worktreeListOutput(targetPath: listedPath), stderr: "")),
      worktreePath: targetPath)

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), merge: try merged(.squash)))

    #expect(outcome.completed == [.terminateSession])
    #expect(
      outcome.failure?.reason
        == .worktreeRemoval(
          .commandFailed(exitCode: 255, stdout: "", stderr: stderr), registration: .dropped))
    #expect(outcome.skipped == [.deleteBranch(name: "topic", tip: try inspectedTip())])
  }

  @Test("登録の読み直しに失敗したら retained へ丸めない")
  func reportsUnknownRegistrationWhenTheFollowUpReadFails() async throws {
    let listStderr = "fatal: not a git repository\n"
    let harness = try WorktreeCloseHarness(
      git: gitStub(
        removeWorktree: .init(exitCode: 255, stdout: "", stderr: "boom\n"),
        worktreeList: .init(exitCode: 128, stdout: "", stderr: listStderr)))

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(
      outcome.failure?.reason
        == .worktreeRemoval(
          .commandFailed(exitCode: 255, stdout: "", stderr: "boom\n"),
          registration: .unknown(.commandFailed(exitCode: 128, stdout: "", stderr: listStderr))))
  }

  @Test("worktree remove が成功したら登録を読み直さない")
  func doesNotReadRegistrationWhenRemovalSucceeds() async throws {
    let harness = try WorktreeCloseHarness()

    _ = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(!(await harness.git.arguments.contains { $0.contains("list") }))
  }

  /// `-D` でも git が拒否する条件は残る。git 2.50.1 実測: 別の worktree が checkout している
  /// branch への `branch --delete --force --` は rc=1 /
  /// `error: cannot delete branch 'topic' used by worktree at '<path>'`。
  @Test("branch -D の拒否は失敗として返す")
  func reportsForcedBranchDeletionRefusal() async throws {
    let stderr = "error: cannot delete branch 'topic' used by worktree at '/repo/other'\n"
    let harness = try WorktreeCloseHarness(
      git: gitStub(deleteBranch: .init(exitCode: 1, stdout: "", stderr: stderr)))

    let outcome = try await harness.run(
      try harness.plan(
        .terminateSession(.removeWorktree(.deleteBranch)), merge: try merged(.squash)))

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(outcome.failure?.step == .deleteBranch(name: "topic", tip: try inspectedTip()))
    #expect(
      outcome.failure?.reason == .git(.commandFailed(exitCode: 1, stdout: "", stderr: stderr)))
    #expect(outcome.skipped.isEmpty)
  }

  @Test("消す worktree 自身を repository directory にはできない")
  func rejectsRepositoryDirectoryEqualToTheRemovedWorktree() throws {
    let path = URL(fileURLWithPath: "/repo/wt")
    #expect(throws: WorktreeCloseExecutorError.repositoryDirectoryIsTheRemovedWorktree(path)) {
      try WorktreeCloseHarness(repositoryDirectory: path)
    }
  }

  /// 実行時に弾くと `terminateSession` を撃った後で `.invalidArguments` を返すことになり、
  /// session 終了は巻き戻せない。
  @Test("絶対パスでない作業ツリーでは executor を作れない", arguments: ["wt", "", "../wt"])
  func rejectsNonAbsoluteWorktreePathAtInitialization(path: String) throws {
    #expect(throws: WorktreeCloseExecutorError.worktreePathNotAbsolute(path)) {
      try WorktreeCloseHarness(worktreePath: path)
    }
  }

  /// 別の worktree の検査と続行確認から作った計画を撃てると、検査されていない worktree が
  /// `--force` で消える。1 step でも撃つ前に弾く。
  @Test("対象の違う計画は1 step も実行せずに拒否する")
  func rejectsPlanBuiltForAnotherWorktree() async throws {
    let harness = try WorktreeCloseHarness()
    let other = try WorktreeCloseHarness.detected(identity: "/repo/.git/worktrees/feature-b")
    let plan = try harness.plan(
      .terminateSession(.removeWorktree(.deleteBranch)), worktree: other, uncommitted: .present,
      merge: try merged(.squash), continuation: .forcingAcknowledgedWarnings)
    #expect(plan.steps.contains(.removeWorktree(force: true)))

    await #expect(
      throws: WorktreeClosePlanMismatch(plan: other.identity, executor: harness.worktree.identity)
    ) {
      try await harness.executor.execute(plan)
    }
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.invocations.isEmpty)
  }

  /// argv を組み立てられなかったときに `nil` (= 成功) を返すと、branch は残ったままなのに
  /// Close は完走したことになる。
  @Test("argv を組み立てられなかった step は成功として報告しない")
  func doesNotReportAnUnexecutedStepAsCompleted() async throws {
    let harness = try WorktreeCloseHarness(git: gitStub(head: headOnBranch("")))
    // `isBranchDeletionAvailable` は空文字を通すが `deleteMergedBranch` は通さない。
    let plan = try harness.plan(
      .terminateSession(.removeWorktree(.deleteBranch)),
      worktree: try WorktreeCloseHarness.detected(branch: ""), merge: try merged(.squash))
    #expect(plan.steps.last == .deleteBranch(name: "", tip: try inspectedTip()))

    let outcome = try await harness.run(plan)

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(outcome.failure?.step == .deleteBranch(name: "", tip: try inspectedTip()))
    #expect(outcome.failure?.reason == .invalidArguments)
    #expect(outcome.skipped.isEmpty)
    #expect(!(await harness.git.arguments.contains { $0.contains("branch") }))
  }

  /// 書き込みと、失敗後の読み直しは**別の runner** を通る (`GitCloseWriteRunner` と `GitRunner`)
  /// ので、両方を1回の Close で押さえる。規約は `expectFixedGitInvocation` の doc コメント。
  @Test("書き込みも失敗後の読み直しも timeout と子プロセス環境を固定して撃つ")
  func fixesTimeoutAndEnvironmentForEveryGitInvocation() async throws {
    let harness = try WorktreeCloseHarness(
      git: refusedRemovalGitStub(), parentEnvironment: pollutedParentEnvironment)

    _ = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    let invocations = await harness.git.repositoryInvocations
    #expect(invocations.map { $0.arguments.contains("list") } == [false, true])
    // 期待値を製品の定数で書くと、その定数を変える変異を落とせない。作業ツリーの実削除は
    // ファイル数に比例するので、書き込みは読み取りより長く待つ。
    expectFixedGitInvocation(invocations[0], timeout: .seconds(120))
    expectFixedGitInvocation(invocations[1], timeout: .seconds(30))
    // 実行直前の読み直し (管理ディレクトリで動く) も同じ規約に従う。
    let preflight = await harness.git.preflightInvocations
    #expect(preflight.count == 4)
    for invocation in preflight {
      expectFixedGitInvocation(invocation, timeout: .seconds(30))
    }
    // branch 削除を含む計画では先端の読み直しが1回増える (Issue #359)。
    let deleting = try WorktreeCloseHarness(
      git: refusedRemovalGitStub(), parentEnvironment: pollutedParentEnvironment)
    _ = try await deleting.run(
      try deleting.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: merged(.squash)))
    let deletingPreflight = await deleting.git.preflightInvocations
    #expect(deletingPreflight.count == 5)
    for invocation in deletingPreflight {
      expectFixedGitInvocation(invocation, timeout: .seconds(30))
    }
  }
}
