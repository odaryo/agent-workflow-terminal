import Adapters
import TerminalCore
import Testing

@Suite("Close 直前の削除を妨げる条件の読み直し (設計書 §3.4)")
struct WorktreeRemovalObstaclesPreflightTests {
  private static let administrativeDirectory = "/repo/.git/worktrees/feature-a"

  @Test("3・4は計画後の lock・submodule で session 終了より前に中止する", arguments: [false, true])
  func abandonsRemovalForNewObstacles(deleteBranch: Bool) async throws {
    let cases: [(Set<String>, WorktreeClosePreflightRefusal)] = [
      ([Self.administrativeDirectory + "/locked"], .worktreeLocked(reason: "portable\nvolume")),
      (
        [Self.administrativeDirectory + "/modules"],
        .worktreeContainsSubmodules(paths: [], hasAdministrativeModules: true)
      ),
    ]
    for (files, expected) in cases {
      let harness = try WorktreeCloseHarness(
        existingFiles: files,
        existingDirectories: files.filter { $0.hasSuffix("/modules") },
        readFile: { _ in "portable\nvolume\n" })
      let plan = try harness.plan(
        .terminateSession(.removeWorktree(deleteBranch ? .deleteBranch : .keepBranch)),
        merge: merged(.ancestor))
      let execution = try await harness.executor.execute(plan)
      #expect(execution == .abandoned(expected))
      #expect(await harness.tmux.invocations.isEmpty)
      #expect(await harness.git.repositoryInvocations.isEmpty)
    }
  }

  @Test("lock と modules が同時にあれば lock の理由で中止する")
  func prioritizesLockOverAdministrativeModules() async throws {
    let harness = try WorktreeCloseHarness(
      existingFiles: [Self.administrativeDirectory + "/locked"],
      existingDirectories: [Self.administrativeDirectory + "/modules"],
      readFile: { _ in "portable\nvolume\n" })
    let plan = try harness.plan(.terminateSession(.removeWorktree(.keepBranch)))
    let execution = try await harness.executor.execute(plan)
    #expect(execution == .abandoned(.worktreeLocked(reason: "portable\nvolume")))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  @Test("modules が通常ファイルなら session 終了と worktree 削除を実行する")
  func permitsRemovalWithAdministrativeModulesFile() async throws {
    let harness = try WorktreeCloseHarness(
      existingFiles: [Self.administrativeDirectory + "/modules"])
    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))
    #expect(outcome.failure == nil)
    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(
      await harness.git.repositoryInvocations.map(\.arguments) == [
        gitArgv("worktree", "remove", "--", "/repo/wt")
      ])
  }

  @Test("削除の妨げを読めなければ session 終了前に中止する")
  func abandonsRemovalWhenObstaclesCannotBeRead() async throws {
    let failure = ProcessRunResult(exitCode: 128, stdout: "", stderr: "fatal: index\n")
    let harness = try WorktreeCloseHarness(git: gitStub(index: failure))
    let plan = try harness.plan(.terminateSession(.removeWorktree(.keepBranch)))
    let execution = try await harness.executor.execute(plan)
    #expect(
      execution
        == .abandoned(
          .observationFailed(
            .git(.commandFailed(exitCode: 128, stdout: "", stderr: failure.stderr)))))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  @Test("2は削除の妨げを読まず git の呼び出しも増やさない")
  func doesNotReadObstaclesForSessionOnlyPlan() async throws {
    let harness = try WorktreeCloseHarness(
      git: gitStub(index: gitNotFound),
      existingFiles: [
        Self.administrativeDirectory + "/locked", Self.administrativeDirectory + "/modules",
      ],
      readFile: { _ in
        Issue.record("選択肢2では locked を読まない")
        return "locked"
      })
    let outcome = try await harness.run(try harness.plan(.terminateSession(.keepWorktree)))
    #expect(outcome.failure == nil)
    // 型注釈が無いと Swift 6.1.2 (CI) が式の型推論を時間内に終えられない。
    let prefix: [String] = [
      "--no-optional-locks", "-C", Self.administrativeDirectory, "--no-pager",
    ]
    let queries: [[String]] = [
      ["symbolic-ref", "--quiet", "HEAD"],
      ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"],
      ["rev-parse", "--verify", "--quiet", "CHERRY_PICK_HEAD"],
      ["rev-parse", "--verify", "--quiet", "REVERT_HEAD"],
    ]
    let expected: [[String]] = queries.map { prefix + $0 }
    let actual: [[String]] = await harness.git.arguments
    #expect(actual == expected)
  }
}
