import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("Close の後始末の実行 (設計書 §3.4)")
struct WorktreeCloseExecutorTests {
  @Test("Close 専用の書き込み command は2種類しか作れない")
  func writeCommandBuildsOnlyTheTwoCleanupCommands() {
    #expect(
      GitCloseWriteCommand.removeWorktree(path: "/repo/wt", force: false)?.arguments == [
        "worktree", "remove", "--", "/repo/wt",
      ])
    #expect(
      GitCloseWriteCommand.removeWorktree(path: "/repo/wt", force: true)?.arguments == [
        "worktree", "remove", "--force", "--", "/repo/wt",
      ])
    #expect(
      GitCloseWriteCommand.deleteMergedBranch(name: "topic")?.arguments == [
        "branch", "--delete", "--", "topic",
      ])
    // `-` 始まりの値も `--` の後ろに置かれるので option としては解釈されない。
    #expect(
      GitCloseWriteCommand.deleteMergedBranch(name: "-D")?.arguments == [
        "branch", "--delete", "--", "-D",
      ])
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
      await harness.tmux.invocations.map(\.arguments) == [
        ["-u", "-L", "awt-test", "kill-session", "-t", "=\(harness.session.rawValue)"]
      ])
    #expect(
      await harness.git.invocations.map(\.arguments) == [
        [
          "--no-optional-locks", "-C", "/repo", "--no-pager", "worktree", "remove", "--",
          "/repo/wt",
        ],
        ["--no-optional-locks", "-C", "/repo", "--no-pager", "branch", "--delete", "--", "topic"],
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
      await harness.git.invocations.map(\.arguments) == [
        [
          "--no-optional-locks", "-C", "/repo", "--no-pager", "worktree", "remove", "--force", "--",
          "/repo/wt",
        ]
      ])
  }

  @Test("session がもう無いことと server が動いていないことは Close の成功")
  func treatsAbsentSessionAndStoppedServerAsSuccess() async throws {
    let session = try WorktreeCloseHarness.sessionName()
    let stderrs =
      ["can't find session: \(session.rawValue)\n"] + tmuxServerAbsentStderrs

    for stderr in stderrs {
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

  /// git が実行を拒否した場合。登録は残っているので Close はやり直せる。
  ///
  /// git 2.50.1 実測 (`mktemp -d` 配下の使い捨て repository): 未commit変更のある worktree へ
  /// `worktree remove --` を撃つと rc=128 /
  /// `fatal: '<path>' contains modified or untracked files, use --force to delete it` になり、
  /// 直後の `worktree list --porcelain` にはその worktree が残っていた。
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
      await harness.git.arguments.last == [
        "--no-optional-locks", "-C", "/repo", "--no-pager", "worktree", "list", "--porcelain", "-z",
      ])
  }

  /// **`worktree remove` は step として atomic ではない。** git 2.50.1 実測 (`mktemp -d` 配下の
  /// 使い捨て repository): clean な worktree のサブディレクトリを `chmod 500` にしてから
  /// `worktree remove --` を撃つと rc=255 / `error: failed to delete '<path>': Permission denied`
  /// になるが、直後の `worktree list --porcelain` からその worktree は消えており、管理ディレクトリ
  /// ごと削除されていた。作業ツリーのディレクトリは中途半端に消えた状態で残る (`--force` を
  /// 付けても rc も結果も同じ)。
  ///
  /// ここを `.retained` へ丸めると、呼び出し側は「何も起きていない」と読む一方、
  /// `GitWorktreeDetector.scan()` は `worktree list` しか見ないので**以後この worktree は
  /// アプリから検出されない**。
  @Test("途中まで消えた worktree remove は「登録が消えた」として返す")
  func reportsDroppedRegistrationWhenRemovalFailsPartway() async throws {
    let stderr = "error: failed to delete '/repo/wt': Permission denied\n"
    let harness = try WorktreeCloseHarness(
      git: gitStub(
        removeWorktree: .init(exitCode: 255, stdout: "", stderr: stderr),
        worktreeList: .init(
          exitCode: 0, stdout: worktreeListOutput(includesTarget: false), stderr: "")))

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

  /// 実行時ではなく構築時に弾く。実行時に弾くと `terminateSession` を撃った後で
  /// `.invalidArguments` を返すことになり、session 終了は巻き戻せない。
  @Test("絶対パスでない作業ツリーでは executor を作れない", arguments: ["wt", "", "../wt"])
  func rejectsNonAbsoluteWorktreePathAtInitialization(path: String) throws {
    #expect(throws: WorktreeCloseExecutorError.worktreePathNotAbsolute(path)) {
      try WorktreeCloseHarness(worktreePath: path)
    }
  }

  /// 別の worktree の検査と続行確認から作った計画をそのまま撃てると、検査されていない worktree が
  /// `--force` で消える。1 step でも撃つ前に弾く。
  @Test("対象の違う計画は1 step も実行せずに拒否する")
  func rejectsPlanBuiltForAnotherWorktree() async throws {
    let harness = try WorktreeCloseHarness()
    let other = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature-b"))
    let plan = try harness.plan(
      .terminateSession(.removeWorktree(.deleteBranch)), worktree: other, uncommitted: .present,
      merge: .merged, continuation: .forcingAcknowledgedWarnings)
    #expect(plan.steps.contains(.removeWorktree(force: true)))

    await #expect(throws: WorktreeClosePlanMismatch(plan: other, executor: harness.identity)) {
      try await harness.executor.execute(plan)
    }
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.invocations.isEmpty)
  }

  /// 撃っていない step を `completed` へ積まない。argv を組み立てられなかったときに `nil`
  /// (= 成功) を返すと、branch は残ったままなのに Close は完走したことになる。
  @Test("argv を組み立てられなかった step は成功として報告しない")
  func doesNotReportAnUnexecutedStepAsCompleted() async throws {
    let harness = try WorktreeCloseHarness()
    // `isBranchDeletionAvailable` は空文字を通すが `deleteMergedBranch` は通さない。
    let plan = try harness.plan(
      .terminateSession(.removeWorktree(.deleteBranch)), branch: "", merge: .merged)
    #expect(plan.steps.last == .deleteBranch(name: ""))

    let outcome = try await harness.executor.execute(plan)

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(outcome.failure?.step == .deleteBranch(name: ""))
    #expect(outcome.failure?.reason == .invalidArguments)
    #expect(outcome.skipped.isEmpty)
    #expect(!(await harness.git.arguments.contains { $0.contains("branch") }))
  }

  /// 書き込み側の timeout と子プロセス環境を固定する。読み取り側は `GitRunnerTests` が固定して
  /// いるが、`GitCloseWriteRunner` は同じ規則を別に持っている (Issue #143) ため、割れたときに
  /// 読み取り側でしか気付けない状態になっている。
  ///
  /// `HOME` を素通しすることが安全に効く: ユーザーの `core.excludesFile` 経由で「何が ignored か」
  /// —— つまり `--force` 無しで消えるもの —— が変わる。
  @Test("書き込みは timeout と子プロセス環境を固定して撃つ")
  func fixesTimeoutAndEnvironmentForWrites() async throws {
    let harness = try WorktreeCloseHarness(
      parentEnvironment: [
        "HOME": "/home/tester", "PATH": "/usr/bin", "LC_ALL": "ja_JP.UTF-8",
        "GIT_DIR": "/elsewhere/.git", "LANG": "ja_JP.UTF-8",
      ])

    _ = try await harness.executor.execute(
      try harness.plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    let invocations = await harness.git.invocations
    #expect(invocations.count == 2)
    for invocation in invocations {
      #expect(
        invocation.environment == ["LC_ALL": "C", "HOME": "/home/tester", "PATH": "/usr/bin"])
      // 作業ツリーの実削除はファイル数に比例するので、読み取り (30秒) より長く待つ。
      #expect(invocation.timeout == .seconds(120))
    }
  }
}

private let removalRefusedStderr =
  "fatal: '/repo/wt' contains modified or untracked files, use --force to delete it\n"

private func refusedRemovalGitStub() -> WorktreeCloseGitStub {
  gitStub(
    removeWorktree: .init(exitCode: 128, stdout: "", stderr: removalRefusedStderr),
    worktreeList: .init(exitCode: 0, stdout: worktreeListOutput(includesTarget: true), stderr: ""))
}

/// `worktree list --porcelain -z` の出力。属性は `\0` 区切りで、record 間は空の属性で区切られる。
private func worktreeListOutput(includesTarget: Bool) -> String {
  let head = String(repeating: "e1", count: 20)
  var output = "worktree /repo\0HEAD \(head)\0branch refs/heads/main\0\0"
  if includesTarget {
    output += "worktree /repo/wt\0HEAD \(head)\0branch refs/heads/topic\0\0"
  }
  return output
}

private func gitStub(
  removeWorktree: ProcessRunResult = .init(exitCode: 0, stdout: "", stderr: ""),
  worktreeList: ProcessRunResult = .init(exitCode: 0, stdout: "", stderr: ""),
  deleteBranch: ProcessRunResult = .init(exitCode: 0, stdout: "", stderr: "")
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
  let session: TmuxSessionName
  let identity: WorktreeIdentity
  let executor: WorktreeCloseExecutor

  init(
    tmux: TmuxSessionRunnerStub = .init(result: stubSuccess()),
    git: WorktreeCloseGitStub = gitStub(),
    repositoryDirectory: URL = URL(fileURLWithPath: "/repo"),
    worktreePath: String = "/repo/wt",
    parentEnvironment: [String: String] = [:]
  ) throws {
    let session = try Self.sessionName()
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature-a"))
    self.tmux = tmux
    self.git = git
    self.session = session
    self.identity = identity
    self.executor = try WorktreeCloseExecutor(
      repositoryDirectory: repositoryDirectory,
      worktree: DetectedWorktree(
        identity: identity, worktreePath: worktreePath, branch: "topic", isProjectRoot: false),
      session: session,
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
    worktree: WorktreeIdentity? = nil,
    branch: String? = "topic",
    uncommitted: UncommittedChangesStatus = .absent,
    merge: BranchMergeStatus = .unmerged,
    continuation: WorktreeRemovalConfirmation.Continuation = .withoutForce
  ) throws -> WorktreeClosePlan {
    try planWorktreeClose(
      worktree: worktree ?? identity, choice: choice, branch: branch,
      defaultBranch: .originHead(branch: "main"),
      confirmation: WorktreeRemovalConfirmation(
        inspection: .init(
          uncommittedChanges: uncommitted, ignoredFiles: .absent, unpushedCommits: .absent,
          branchMerge: merge),
        continuation: continuation))
  }

  static func sessionName() throws -> TmuxSessionName {
    TmuxSessionName(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature-a")))
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
