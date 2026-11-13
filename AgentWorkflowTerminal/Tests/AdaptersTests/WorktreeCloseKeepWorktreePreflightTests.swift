import TerminalCore
import Testing

@testable import Adapters

@Suite("§3.4 worktree を残す Close の実行前確認")
struct WorktreeCloseKeepWorktreePreflightTests {
  @Test("detached の計画でも選択肢2を実行できる")
  func executesDetachedPlanWithoutReadingHead() async throws {
    let harness = try WorktreeCloseHarness(git: gitStub(head: gitNotFound))
    let detached = try WorktreeCloseHarness.detected(branch: nil)
    let plan = try harness.plan(.terminateSession(.keepWorktree), worktree: detached)
    #expect(plan.branch == nil)

    let execution = try await harness.executor.execute(plan)

    #expect(
      execution
        == .executed(
          WorktreeCloseOutcome(completed: [.terminateSession], failure: nil, skipped: [])))
    #expect(await harness.git.arguments.contains { $0.contains("symbolic-ref") } == false)
  }

  @Test(
    "選択肢2は HEAD が detached・別 branch・読み取り不能でも session を終了する",
    arguments: [
      gitNotFound, headOnBranch("other"),
      ProcessRunResult(exitCode: 128, stdout: "", stderr: "HEAD read failed\n"),
    ])
  func terminatesWithoutReadingHead(head: ProcessRunResult) async throws {
    let harness = try WorktreeCloseHarness(git: gitStub(head: head))
    let plan = try harness.plan(.terminateSession(.keepWorktree))
    #expect(plan.branch == "topic")

    let execution = try await harness.executor.execute(plan)

    #expect(
      execution
        == .executed(
          WorktreeCloseOutcome(completed: [.terminateSession], failure: nil, skipped: [])))
    #expect(
      await harness.tmux.invocations.filter { $0.arguments.contains("kill-session") }.count == 1)
    #expect(await harness.git.repositoryInvocations.isEmpty)
    #expect(await harness.git.arguments.contains { $0.contains("symbolic-ref") } == false)
    #expect(await harness.git.arguments.contains { $0.last == "MERGE_HEAD" })
  }

  @Test(
    "選択肢2は HEAD にかかわらず途中状態で session 終了を中止する",
    arguments: [gitNotFound, headOnBranch("other"), headOnBranch("topic")])
  func refusesOperationsEvenWithoutRemoval(head: ProcessRunResult) async throws {
    let harness = try WorktreeCloseHarness(
      git: gitStub(head: head, references: ["MERGE_HEAD": gitSuccess]))

    let execution = try await harness.executor.execute(
      try harness.plan(.terminateSession(.keepWorktree)))

    #expect(execution == .abandoned(.operationInProgress([.merge])))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  @Test("選択肢2は HEAD が detached でも途中状態の観測失敗を返す")
  func refusesFailedOperationObservation() async throws {
    let failure = ProcessRunResult(exitCode: 128, stdout: "", stderr: "operation read failed\n")
    let harness = try WorktreeCloseHarness(
      git: gitStub(head: gitNotFound, references: ["REVERT_HEAD": failure]))

    let execution = try await harness.executor.execute(
      try harness.plan(.terminateSession(.keepWorktree)))

    #expect(
      execution
        == .abandoned(
          .observationFailed(
            .git(.commandFailed(exitCode: 128, stdout: "", stderr: failure.stderr)))))
    #expect(await harness.tmux.invocations.isEmpty)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }
}
