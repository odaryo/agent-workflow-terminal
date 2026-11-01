import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("socket 欠落時の Close (設計書 §3.4)")
struct WorktreeCloseOrphanedServerTests {
  @Test("取り残された server があれば Close は失敗し worktree を削除しない")
  func refusesRemovalWithOrphanedServer() async throws {
    let runner = OrphanedServerRunnerStub(
      result: stubSuccess(stdout: "p123\nf6\nn/private/tmp/tmux-501/default\n"))
    let harness = try harness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.completed.isEmpty)
    #expect(outcome.failure?.step == .terminateSession)
    #expect(
      outcome.failure?.reason
        == .orphanedTmuxServer(
          socketPath: "/private/tmp/tmux-501/default", .orphaned(processIDs: [123])))
    #expect(outcome.skipped == [.removeWorktree(force: false)])
    #expect(await harness.git.repositoryInvocations.isEmpty)
    #expect(await runner.invocations.count == 1)
  }

  @Test("probe が確定できなければ Close は失敗し worktree を削除しない")
  func refusesRemovalWithUndeterminedServer() async throws {
    let runner = OrphanedServerRunnerStub(
      result: .failure(.timedOut(exitCode: nil, stdout: "", stderr: "")))
    let harness = try harness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.completed.isEmpty)
    #expect(outcome.failure?.step == .terminateSession)
    #expect(outcome.skipped == [.removeWorktree(force: false)])
    #expect(await harness.git.repositoryInvocations.isEmpty)
    #expect(await runner.invocations.count == 1)
    let failure = try #require(outcome.failure)
    guard case .orphanedTmuxServer(let path, .undetermined(let reason)) = failure.reason
    else {
      Issue.record("socket path と undetermined を保持する失敗を期待した")
      return
    }
    #expect(path == "/private/tmp/tmux-501/default")
    #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test("probe が absent なら session 終了を成功として worktree を削除する")
  func removesWorktreeWithAbsentServer() async throws {
    let runner = OrphanedServerRunnerStub(result: stubFailure(stderr: ""))
    let harness = try harness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.failure == nil)
    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(outcome.skipped.isEmpty)
    #expect(
      await harness.git.repositoryInvocations.map(\.arguments)
        == [gitArgv("worktree", "remove", "--", "/repo/wt")])
    #expect(await runner.invocations.count == 1)
  }

  private func harness(runner: OrphanedServerRunnerStub) throws -> WorktreeCloseHarness {
    try WorktreeCloseHarness(
      tmux: .init { arguments in
        if arguments.contains("list-sessions") { return stubSuccess() }
        return stubFailure(stderr: tmuxServerSocketMissingStderr)
      },
      orphanedServerProbe: TmuxOrphanedServerProbe(runner: runner))
  }
}
