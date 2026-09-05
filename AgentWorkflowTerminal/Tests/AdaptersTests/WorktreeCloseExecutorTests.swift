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
        == ["branch", "--delete", "--", "topic"])
    // `-` 始まりの値も `--` の後ろに置かれるので option としては解釈されない。
    #expect(
      GitCloseWriteCommand.deleteMergedBranch(name: "-D")?.arguments
        == ["branch", "--delete", "--", "-D"])
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

    let outcome = try await harness.executor.execute(try harness.plan(.hideFromUI))

    #expect(outcome == WorktreeCloseOutcome(completed: [], failure: nil, skipped: []))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.invocations.isEmpty)
  }

  @Test("session 終了・worktree 削除・branch 削除をこの順に撃つ")
  func executesStepsInOrder() async throws {
    let harness = try WorktreeCloseHarness()

    let outcome = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(
      outcome.completed == [
        .terminateSession, .removeWorktree(force: false), .deleteBranch(name: "topic"),
      ])
    #expect(outcome.failure == nil)
    #expect(outcome.skipped.isEmpty)
    #expect(
      await harness.git.invocations.map(\.arguments) == [
        gitArgv("worktree", "remove", "--", "/repo/wt"),
        gitArgv("branch", "--delete", "--", "topic"),
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

    _ = try await harness.executor.execute(try harness.plan(.terminateSession(.keepWorktree)))

    #expect(
      await harness.tmux.invocations.map(\.arguments) == [
        ["-u", "-L", "awt-test", "kill-session", "-t", "=\(expectedSessionName)"]
      ])
  }

  @Test("承知のうえでの続行では worktree remove に --force が付く")
  func passesForceWhenConfirmed() async throws {
    let harness = try WorktreeCloseHarness()

    let outcome = try await harness.executor.execute(
      try harness.plan(
        .terminateSession(.removeWorktree(.keepBranch)), uncommitted: .present,
        continuation: .forcingAcknowledgedWarnings))

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: true)])
    #expect(
      await harness.git.invocations.map(\.arguments)
        == [gitArgv("worktree", "remove", "--force", "--", "/repo/wt")])
  }

  @Test("session がもう無いことと server が動いていないことは Close の成功")
  func treatsAbsentSessionAndStoppedServerAsSuccess() async throws {
    for stderr in ["can't find session: awt-feature-a-219261c3\n"] + tmuxServerAbsentStderrs {
      let harness = try WorktreeCloseHarness(tmux: .init(result: stubFailure(stderr: stderr)))

      let outcome = try await harness.executor.execute(
        try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

      #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
      #expect(outcome.failure == nil)
    }
  }

  @Test("分類できない tmux の失敗では worktree を消さない", arguments: tmuxNotServerAbsentStderrs)
  func stopsBeforeRemovalWhenSessionTerminationFails(stderr: String) async throws {
    let harness = try WorktreeCloseHarness(tmux: .init(result: stubFailure(stderr: stderr)))

    let outcome = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(outcome.completed.isEmpty)
    #expect(outcome.failure?.step == .terminateSession)
    #expect(
      outcome.failure?.reason
        == .tmux(.tmux(.commandFailed(exitCode: 1, stdout: "", stderr: stderr))))
    #expect(outcome.skipped == [.removeWorktree(force: false), .deleteBranch(name: "topic")])
    #expect(await harness.git.invocations.isEmpty)
  }

  @Test("worktree remove が拒否されたら branch は消さない")
  func stopsBeforeBranchDeletionWhenRemovalIsRefused() async throws {
    let harness = try WorktreeCloseHarness(git: refusedRemovalGitStub())

    let outcome = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(outcome.completed == [.terminateSession])
    #expect(outcome.failure?.step == .removeWorktree(force: false))
    #expect(outcome.skipped == [.deleteBranch(name: "topic")])
    #expect(!(await harness.git.arguments.contains { $0.contains("branch") }))
  }

  /// git が実行を拒否した場合。git 2.50.1 実測 (`mktemp -d` 配下の使い捨て repository): 未commit
  /// 変更のある worktree への `worktree remove --` は rc=128 /
  /// `fatal: '<path>' contains modified or untracked files, use --force to delete it` で、
  /// 直後の list にはその worktree が `prunable` の付かない素の record のまま残っていた。
  @Test("実行を拒否された worktree remove は「登録が残っている」として返す")
  func reportsRetainedRegistrationWhenRemovalIsRefused() async throws {
    let harness = try WorktreeCloseHarness(git: refusedRemovalGitStub())

    let outcome = try await harness.executor.execute(
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
  @Test("prunable な record は「残っているが scan に載らない」として返す")
  func reportsRetainedButNotScannableWhenTheRecordIsPrunable() async throws {
    let stderr = "error: failed to delete '.git/worktrees/wt': Permission denied\n"
    let listed = worktreeListOutput(
      targetAttributes: ["prunable gitdir file points to non-existent location"])
    let harness = try WorktreeCloseHarness(
      git: gitStub(
        removeWorktree: .init(exitCode: 255, stdout: "", stderr: stderr),
        worktreeList: .init(exitCode: 0, stdout: listed, stderr: "")))

    let outcome = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(outcome.completed == [.terminateSession])
    #expect(
      outcome.failure?.reason
        == .worktreeRemoval(
          .commandFailed(exitCode: 255, stdout: "", stderr: stderr),
          registration: .retainedButNotScannable))
    #expect(outcome.skipped == [.deleteBranch(name: "topic")])
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

    let outcome = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(outcome.completed == [.terminateSession])
    #expect(
      outcome.failure?.reason
        == .worktreeRemoval(
          .commandFailed(exitCode: 255, stdout: "", stderr: stderr), registration: .dropped))
    #expect(outcome.skipped == [.deleteBranch(name: "topic")])
  }

  @Test("登録の読み直しに失敗したら retained へ丸めない")
  func reportsUnknownRegistrationWhenTheFollowUpReadFails() async throws {
    let listStderr = "fatal: not a git repository\n"
    let harness = try WorktreeCloseHarness(
      git: gitStub(
        removeWorktree: .init(exitCode: 255, stdout: "", stderr: "boom\n"),
        worktreeList: .init(exitCode: 128, stdout: "", stderr: listStderr)))

    let outcome = try await harness.executor.execute(
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

    _ = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(!(await harness.git.arguments.contains { $0.contains("list") }))
  }

  @Test("branch -d の拒否は失敗として返し、-D へ格上げしない")
  func reportsBranchDeletionRefusalWithoutEscalating() async throws {
    let stderr = "error: the branch 'topic' is not fully merged\n"
    let harness = try WorktreeCloseHarness(
      git: gitStub(deleteBranch: .init(exitCode: 1, stdout: "", stderr: stderr)))

    let outcome = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(outcome.failure?.step == .deleteBranch(name: "topic"))
    #expect(
      outcome.failure?.reason == .git(.commandFailed(exitCode: 1, stdout: "", stderr: stderr)))
    #expect(outcome.skipped.isEmpty)
    let arguments = await harness.git.arguments
    #expect(!arguments.contains { $0.contains("-D") || $0.contains("--force") })
  }

  @Test("消す worktree 自身を repository directory にはできない")
  func rejectsRepositoryDirectoryEqualToTheRemovedWorktree() throws {
    #expect(
      throws: WorktreeCloseExecutorError.repositoryDirectoryIsTheRemovedWorktree(
        URL(fileURLWithPath: "/repo/wt"))
    ) {
      try WorktreeCloseHarness(repositoryDirectory: URL(fileURLWithPath: "/repo/wt"))
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
      merge: .merged, continuation: .forcingAcknowledgedWarnings)
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
    let harness = try WorktreeCloseHarness()
    // `isBranchDeletionAvailable` は空文字を通すが `deleteMergedBranch` は通さない。
    let plan = try harness.plan(
      .terminateSession(.removeWorktree(.deleteBranch)),
      worktree: try WorktreeCloseHarness.detected(branch: ""), merge: .merged)
    #expect(plan.steps.last == .deleteBranch(name: ""))

    let outcome = try await harness.executor.execute(plan)

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(outcome.failure?.step == .deleteBranch(name: ""))
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

    _ = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    let invocations = await harness.git.invocations
    #expect(invocations.map { $0.arguments.contains("list") } == [false, true])
    // 期待値を製品の定数で書くと、その定数を変える変異を落とせない。作業ツリーの実削除は
    // ファイル数に比例するので、書き込みは読み取りより長く待つ。
    expectFixedGitInvocation(invocations[0], timeout: .seconds(120))
    expectFixedGitInvocation(invocations[1], timeout: .seconds(30))
  }
}

/// **新しく git / tmux 呼び出しを足したら、その1回について timeout と子プロセス環境を固定する。**
/// Round 11・12・13 で3回続けて、新設した呼び出しだけが未固定のまま残った。`arguments` を見る
/// テストは代わりにならない (`arguments.last` の検査は timeout の変異を落とさない)。環境は
/// `LC_ALL=C` と `HOME` / `PATH` だけを通す —— `HOME` は `core.excludesFile` 経由で
/// 「何が ignored か」、つまり `--force` 無しで消えるものを変えるので、落としてはいけない。
private func expectFixedGitInvocation(
  _ invocation: WorktreeCloseGitStub.Invocation,
  timeout: Duration,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(
    invocation.environment == ["LC_ALL": "C", "HOME": "/home/tester", "PATH": "/usr/bin"],
    sourceLocation: sourceLocation)
  #expect(invocation.timeout == timeout, sourceLocation: sourceLocation)
}

/// `LC_ALL` が上書きされ、`GIT_DIR` と `LANG` が落ちることを確かめるための親環境。
private let pollutedParentEnvironment = [
  "HOME": "/home/tester", "PATH": "/usr/bin", "LC_ALL": "ja_JP.UTF-8",
  "GIT_DIR": "/elsewhere/.git", "LANG": "ja_JP.UTF-8",
]

private let removalRefusedStderr =
  "fatal: '/repo/wt' contains modified or untracked files, use --force to delete it\n"

private func refusedRemovalGitStub() -> WorktreeCloseGitStub {
  gitStub(
    removeWorktree: .init(exitCode: 128, stdout: "", stderr: removalRefusedStderr),
    worktreeList: .init(exitCode: 0, stdout: worktreeListOutput(), stderr: ""))
}

/// `worktree list --porcelain -z` の出力。属性は `\0` 区切りで、record 間は空の属性で区切られる。
/// `targetPath` が `nil` なら対象の record を置かない。属性の並びは git 2.50.1 の生の出力を
/// `cat -v` で確認して写した (`^@` が `\0`): `worktree <path>^@HEAD <oid>^@branch
/// refs/heads/p6^@prunable gitdir file points to non-existent location^@^@`
private func worktreeListOutput(
  targetPath: String? = "/repo/wt", targetAttributes: [String] = []
) -> String {
  let head = String(repeating: "e1", count: 20)
  var output = "worktree /repo\0HEAD \(head)\0branch refs/heads/main\0\0"
  guard let targetPath else { return output }
  output += "worktree \(targetPath)\0HEAD \(head)\0branch refs/heads/topic\0"
  output += targetAttributes.map { $0 + "\0" }.joined() + "\0"
  return output
}

private func gitArgv(_ rest: String...) -> [String] {
  ["--no-optional-locks", "-C", "/repo", "--no-pager"] + rest
}

private let gitSuccess = ProcessRunResult(exitCode: 0, stdout: "", stderr: "")

private func gitStub(
  removeWorktree: ProcessRunResult = gitSuccess, worktreeList: ProcessRunResult = gitSuccess,
  deleteBranch: ProcessRunResult = gitSuccess
) -> WorktreeCloseGitStub {
  WorktreeCloseGitStub { arguments in
    if arguments.contains("remove") { return removeWorktree }
    if arguments.contains("list") { return worktreeList }
    return deleteBranch
  }
}

private struct WorktreeCloseHarness {
  let tmux: TmuxSessionRunnerStub
  let git: WorktreeCloseGitStub
  let worktree: DetectedWorktree
  let executor: WorktreeCloseExecutor

  init(
    tmux: TmuxSessionRunnerStub = .init(result: stubSuccess()),
    git: WorktreeCloseGitStub = gitStub(),
    repositoryDirectory: URL = URL(fileURLWithPath: "/repo"),
    identity: String = "/repo/.git/worktrees/feature-a",
    worktreePath: String = "/repo/wt",
    parentEnvironment: [String: String] = [:]
  ) throws {
    let worktree = try Self.detected(identity: identity, worktreePath: worktreePath)
    self.tmux = tmux
    self.git = git
    self.worktree = worktree
    self.executor = try WorktreeCloseExecutor(
      repositoryDirectory: repositoryDirectory,
      worktree: worktree,
      sessionOperations: TmuxSessionOperations(
        runner: try TmuxRunner(
          socketName: "awt-test", processRunner: tmux,
          executableCandidates: [URL(fileURLWithPath: "/test/bin/tmux")], parentEnvironment: [:],
          isExecutableFile: { _ in true })),
      processRunner: git, executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: parentEnvironment, isExecutableFile: { _ in true })
  }

  func plan(
    _ choice: WorktreeCloseChoice,
    worktree: DetectedWorktree? = nil,
    uncommitted: UncommittedChangesStatus = .absent,
    merge: BranchMergeStatus = .unmerged,
    continuation: WorktreeRemovalConfirmation.Continuation = .withoutForce
  ) throws -> WorktreeClosePlan {
    try planWorktreeClose(
      worktree: worktree ?? self.worktree, choice: choice,
      defaultBranch: .originHead(branch: "main"),
      confirmation: WorktreeRemovalConfirmation(
        inspection: .init(
          uncommittedChanges: uncommitted, ignoredFiles: .absent, unpushedCommits: .absent,
          branchMerge: merge),
        continuation: continuation))
  }

  static func detected(
    identity: String = "/repo/.git/worktrees/feature-a",
    worktreePath: String = "/repo/wt",
    branch: String? = "topic"
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: identity)), worktreePath: worktreePath,
      branch: branch, isProjectRoot: false)
  }
}

private actor WorktreeCloseGitStub: ProcessRunning {
  struct Invocation: Sendable, Equatable {
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
  }

  private let handler: @Sendable ([String]) -> ProcessRunResult
  private(set) var invocations: [Invocation] = []

  var arguments: [[String]] { invocations.map(\.arguments) }

  init(handler: @escaping @Sendable ([String]) -> ProcessRunResult) {
    self.handler = handler
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) -> ProcessRunResult {
    invocations.append(.init(arguments: arguments, environment: environment, timeout: timeout))
    return handler(arguments)
  }
}
