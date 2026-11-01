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

  @Test("一覧が socket 欠落を投げても、probe が absent なら番号1の終了へ進んで worktree を削除する")
  func removesWorktreeWhenListReportsMissingSocketOfAbsentServer() async throws {
    let runner = OrphanedServerRunnerStub(result: stubFailure(stderr: ""))
    let harness = try listFailingHarness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.failure == nil)
    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(await runner.invocations.count == 1)
    #expect(await killSessionCount(harness) == 1)
    #expect(
      await harness.git.repositoryInvocations.map(\.arguments)
        == [gitArgv("worktree", "remove", "--", "/repo/wt")])
  }

  @Test("一覧が socket 欠落を投げ、取り残された server があれば、session の終了も削除も撃たずに失敗する")
  func refusesRemovalWhenListReportsMissingSocketOfOrphanedServer() async throws {
    let runner = OrphanedServerRunnerStub(
      result: stubSuccess(stdout: "p123\nf6\nn/private/tmp/tmux-501/default\n"))
    let harness = try listFailingHarness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.completed.isEmpty)
    #expect(outcome.failure?.step == .terminateSession)
    #expect(
      outcome.failure?.reason
        == .orphanedTmuxServer(
          socketPath: "/private/tmp/tmux-501/default", .orphaned(processIDs: [123])))
    #expect(outcome.skipped == [.removeWorktree(force: false)])
    #expect(await runner.invocations.count == 1)
    #expect(await killSessionCount(harness) == 0)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  @Test("一覧が socket 欠落を投げ、probe が確定できなければ、session の終了も削除も撃たずに失敗する")
  func refusesRemovalWhenListReportsMissingSocketOfUndeterminedServer() async throws {
    let runner = OrphanedServerRunnerStub(
      result: .failure(.timedOut(exitCode: nil, stdout: "", stderr: "")))
    let harness = try listFailingHarness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.completed.isEmpty)
    #expect(outcome.skipped == [.removeWorktree(force: false)])
    #expect(await killSessionCount(harness) == 0)
    #expect(await harness.git.repositoryInvocations.isEmpty)
    let failure = try #require(outcome.failure)
    guard case .orphanedTmuxServer("/private/tmp/tmux-501/default", .undetermined) = failure.reason
    else {
      Issue.record("socket path と undetermined を保持する失敗を期待したが、\(failure.reason) が返った")
      return
    }
  }

  @Test("一覧も終了も socket 欠落を投げ、probe が2回とも absent なら worktree を削除する")
  func removesWorktreeWhenListAndKillBothReportAbsentServer() async throws {
    let runner = SequencedOrphanedServerRunnerStub(results: [
      stubFailure(stderr: ""), stubFailure(stderr: ""),
    ])
    let harness = try bothFailingHarness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.failure == nil)
    #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
    #expect(await runner.callCount == 2)
    #expect(
      await harness.git.repositoryInvocations.map(\.arguments)
        == [gitArgv("worktree", "remove", "--", "/repo/wt")])
  }

  /// 一覧で不在を確かめた後でも、終了の socket 欠落を素通しにしない (変異 M7)。一覧と終了の間に
  /// server が起きて socket を失うことはありうる。
  @Test("一覧の probe が absent でも、終了の probe が orphaned なら worktree を削除しない")
  func refusesRemovalWhenKillProbeFindsOrphanedServer() async throws {
    let runner = SequencedOrphanedServerRunnerStub(results: [
      stubFailure(stderr: ""),
      stubSuccess(stdout: "p123\nf6\nn\(missingSocketPath)\n"),
    ])
    let harness = try bothFailingHarness(runner: runner)

    let outcome = try await harness.run(
      try harness.plan(.terminateSession(.removeWorktree(.keepBranch))))

    #expect(outcome.completed.isEmpty)
    #expect(
      outcome.failure?.reason
        == .orphanedTmuxServer(socketPath: missingSocketPath, .orphaned(processIDs: [123])))
    #expect(outcome.skipped == [.removeWorktree(force: false)])
    #expect(await runner.callCount == 2)
    #expect(await harness.git.repositoryInvocations.isEmpty)
  }

  /// 作られることのないディレクトリの下に置く。probe はパスに socket が在るかも見るため、
  /// 実機に在りうるパス (`…/tmux-501/default`) では結果が実行環境に左右される。
  private var missingSocketPath: String {
    "/private/tmp/awt-close-never-created-0f3c9a/tmux-501/awt-test"
  }

  private func bothFailingHarness(
    runner: SequencedOrphanedServerRunnerStub
  ) throws -> WorktreeCloseHarness {
    let stderr = "error connecting to \(missingSocketPath) (No such file or directory)\n"
    return try WorktreeCloseHarness(
      tmux: .init(result: stubFailure(stderr: stderr)),
      orphanedServerProbe: TmuxOrphanedServerProbe(runner: runner))
  }

  /// `kill-session` は成功させる。一覧の socket 欠落だけで probe に至ることを確かめるため。
  private func listFailingHarness(runner: OrphanedServerRunnerStub) throws -> WorktreeCloseHarness {
    try WorktreeCloseHarness(
      tmux: .init { arguments in
        if arguments.contains("list-sessions") {
          return stubFailure(stderr: tmuxServerSocketMissingStderr)
        }
        return stubSuccess()
      },
      orphanedServerProbe: TmuxOrphanedServerProbe(runner: runner, socketExists: socketIsMissing))
  }

  private func killSessionCount(_ harness: WorktreeCloseHarness) async -> Int {
    await harness.tmux.invocations.filter { $0.arguments.contains("kill-session") }.count
  }

  private func harness(runner: OrphanedServerRunnerStub) throws -> WorktreeCloseHarness {
    try WorktreeCloseHarness(
      tmux: .init { arguments in
        if arguments.contains("list-sessions") { return stubSuccess() }
        return stubFailure(stderr: tmuxServerSocketMissingStderr)
      },
      orphanedServerProbe: TmuxOrphanedServerProbe(runner: runner, socketExists: socketIsMissing))
  }
}

/// 呼ばれた順に `results` を返す。尽きたら最後の結果を返し続ける。
actor SequencedOrphanedServerRunnerStub: ProcessRunning {
  private let results: [TmuxSessionStubResult]
  private(set) var callCount = 0

  init(results: [TmuxSessionStubResult]) {
    self.results = results
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    let result = results[min(callCount, results.count - 1)]
    callCount += 1
    return try result.get()
  }
}
