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

    let outcome = await harness.executor.execute(try plan(.hideFromUI))

    #expect(outcome == WorktreeCloseOutcome(completed: [], failure: nil, skipped: []))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.invocations.isEmpty)
  }

  @Test("session 終了・worktree 削除・branch 削除をこの順に撃つ")
  func executesStepsInOrder() async throws {
    let harness = try WorktreeCloseHarness()

    let outcome = await harness.executor.execute(
      try plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

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
      await harness.git.invocations == [
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

    let outcome = await harness.executor.execute(
      try plan(
        .terminateSession(.removeWorktree(.keepBranch)), uncommitted: .present,
        continuation: .forcingAcknowledgedWarnings))

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: true)])
    #expect(
      await harness.git.invocations == [
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

      let outcome = await harness.executor.execute(
        try plan(.terminateSession(.removeWorktree(.keepBranch))))

      #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
      #expect(outcome.failure == nil)
    }
  }

  @Test("分類できない tmux の失敗では worktree を消さない", arguments: tmuxNotServerAbsentStderrs)
  func stopsBeforeRemovalWhenSessionTerminationFails(stderr: String) async throws {
    let harness = try WorktreeCloseHarness(tmux: .init(result: stubFailure(stderr: stderr)))

    let outcome = await harness.executor.execute(
      try plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

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
    let stderr =
      "fatal: '/repo/wt' contains modified or untracked files, use --force to delete it\n"
    let harness = try WorktreeCloseHarness(
      git: .init { arguments in
        arguments.contains("worktree")
          ? .init(exitCode: 128, stdout: "", stderr: stderr)
          : .init(exitCode: 0, stdout: "", stderr: "")
      })

    let outcome = await harness.executor.execute(
      try plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(outcome.completed == [.terminateSession])
    #expect(outcome.failure?.step == .removeWorktree(force: false))
    #expect(
      outcome.failure?.reason == .git(.commandFailed(exitCode: 128, stdout: "", stderr: stderr)))
    #expect(outcome.skipped == [.deleteBranch(name: "topic")])
  }

  @Test("branch -d の拒否は失敗として返し、-D へ格上げしない")
  func reportsBranchDeletionRefusalWithoutEscalating() async throws {
    let stderr = "error: the branch 'topic' is not fully merged\n"
    let harness = try WorktreeCloseHarness(
      git: .init { arguments in
        arguments.contains("branch")
          ? .init(exitCode: 1, stdout: "", stderr: stderr)
          : .init(exitCode: 0, stdout: "", stderr: "")
      })

    let outcome = await harness.executor.execute(
      try plan(.terminateSession(.removeWorktree(.deleteBranch)), merge: .merged))

    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(outcome.failure?.step == .deleteBranch(name: "topic"))
    #expect(
      outcome.failure?.reason == .git(.commandFailed(exitCode: 1, stdout: "", stderr: stderr)))
    #expect(outcome.skipped.isEmpty)
    let invocations = await harness.git.invocations
    #expect(!invocations.contains { $0.contains("-D") || $0.contains("--force") })
  }

  @Test("消す worktree 自身を repository directory にはできない")
  func rejectsRepositoryDirectoryEqualToTheRemovedWorktree() throws {
    #expect(throws: GitRunnerError.invalidRepositoryDirectory(URL(fileURLWithPath: "/repo/wt"))) {
      try WorktreeCloseHarness(repositoryDirectory: URL(fileURLWithPath: "/repo/wt"))
    }
  }

  private func plan(
    _ choice: WorktreeCloseChoice,
    uncommitted: UncommittedChangesStatus = .absent,
    merge: BranchMergeStatus = .unmerged,
    continuation: WorktreeRemovalConfirmation.Continuation = .withoutForce
  ) throws -> WorktreeClosePlan {
    try planWorktreeClose(
      choice: choice, branch: "topic", defaultBranch: .originHead(branch: "main"),
      confirmation: WorktreeRemovalConfirmation(
        inspection: .init(
          uncommittedChanges: uncommitted, ignoredFiles: .absent, unpushedCommits: .absent,
          branchMerge: merge),
        continuation: continuation))
  }
}

private struct WorktreeCloseHarness {
  let tmux: TmuxSessionRunnerStub
  let git: WorktreeCloseGitStub
  let session: TmuxSessionName
  let executor: WorktreeCloseExecutor

  init(
    tmux: TmuxSessionRunnerStub = .init(result: stubSuccess()),
    git: WorktreeCloseGitStub = .init(),
    repositoryDirectory: URL = URL(fileURLWithPath: "/repo")
  ) throws {
    let session = try Self.sessionName()
    self.tmux = tmux
    self.git = git
    self.session = session
    self.executor = try WorktreeCloseExecutor(
      repositoryDirectory: repositoryDirectory, worktreePath: "/repo/wt", session: session,
      sessionOperations: TmuxSessionOperations(
        runner: try TmuxRunner(
          socketName: "awt-test", processRunner: tmux,
          executableCandidates: [URL(fileURLWithPath: "/test/bin/tmux")], parentEnvironment: [:],
          isExecutableFile: { _ in true })),
      processRunner: git, executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: [:], isExecutableFile: { _ in true })
  }

  static func sessionName() throws -> TmuxSessionName {
    TmuxSessionName(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/feature-a")))
  }
}

private actor WorktreeCloseGitStub: ProcessRunning {
  private let handler: @Sendable ([String]) -> ProcessRunResult
  private(set) var invocations: [[String]] = []

  init(
    handler: @escaping @Sendable ([String]) -> ProcessRunResult = { _ in
      .init(exitCode: 0, stdout: "", stderr: "")
    }
  ) {
    self.handler = handler
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) -> ProcessRunResult {
    invocations.append(arguments)
    return handler(arguments)
  }
}
