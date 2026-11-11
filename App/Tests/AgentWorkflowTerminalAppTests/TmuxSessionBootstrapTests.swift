import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

/// gate はプロセス全体で共有されるので、並行させるとテストが互いの bootstrap の終了を待って遅くなる (Issue #544)。
@Suite("bootstrap のプロセス内直列化 (Issue #512)", .serialized)
struct TmuxSessionBootstrapTests {
  @Test("別 Project の create が失敗しても、bootstrap 後の probe から後始末まで入り交じらない")
  func serializesAcrossProvisioners() async throws {
    let process = BootstrapProcessRunner()
    let first = try makeProvisioner(process)
    let second = try makeProvisioner(process)
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let firstKey = try #require(TerminalSessionKey(identity: identity, index: 1))
    let secondKey = try #require(TerminalSessionKey(identity: identity, index: 2))

    async let firstResult = first.attachCommand(for: firstKey, workingDirectory: "/")
    async let secondResult = second.attachCommand(for: secondKey, workingDirectory: "/")
    let results = await [firstResult, secondResult]

    for result in results {
      #expect(
        result
          == .failure(
            .operation(
              .tmux(.commandFailed(exitCode: 1, stdout: "", stderr: "permission denied\n")))))
    }
    let calls = await process.calls
    #expect(calls.count == 8)
    let bootstrapCalls = Array(calls.dropFirst(2))
    let firstProbe = try #require(bootstrapCalls.first)
    let firstTarget = try #require(firstProbe.last)
    let names = [TmuxSessionName(key: firstKey).rawValue, TmuxSessionName(key: secondKey).rawValue]
    let firstName = try #require(names.first { "=\($0)" == firstTarget })
    let secondName = try #require(names.first { $0 != firstName })
    #expect(
      bootstrapCalls == expectedCalls(name: firstName) + expectedCalls(name: secondName))
  }

  @Test(
    "bootstrap 後にキャンセルされても、キャンセルされていない Task で後始末する",
    .timeLimit(.minutes(1)))
  func cleansUpAfterCancellation() async throws {
    let process = BootstrapProcessRunner(initialProbeCount: 1, bootstrapProbeWait: .untilCancelled)
    let provisioner = try makeProvisioner(process)
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let key = try #require(TerminalSessionKey(identity: identity, index: 1))
    let task = Task {
      let result = await provisioner.attachCommand(for: key, workingDirectory: "/")
      await process.releaseAll()
      return result
    }
    defer { task.cancel() }

    // .timeLimit はテストの Task をキャンセルするだけで、キャンセルに反応しない待ちからは抜けない。
    // プロダクションが退行して probe に届かなくなっても、止まり続けずに expectation の失敗で終える。
    try await withTaskCancellationHandler {
      await process.waitForBootstrapProbe()
      try #require(await process.calls.count == 2)
      task.cancel()

      #expect(await task.value == .failure(.operation(.tmux(.process(.cancelled)))))
      #expect(
        await process.calls.last == [
          "-u", "kill-session", "-t", "=awt-bootstrap-server-do-not-use",
        ])
    } onCancel: {
      task.cancel()
      Task { await process.releaseAll() }
    }
  }

  private func expectedCalls(name: String) -> [[String]] {
    [
      ["-u", "has-session", "-t", "=\(name)"],
      ["-u", "new-session", "-d", "-s", name, "-c", "/", "-P", "-F", "#{session_id}"],
      ["-u", "kill-session", "-t", "=awt-bootstrap-server-do-not-use"],
    ]
  }

  private func makeProvisioner(_ process: BootstrapProcessRunner) throws -> TmuxSessionProvisioner {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let runner = try TmuxRunner(
      server: .userDefault, processRunner: process, executableCandidates: [executable])
    return TmuxSessionProvisioner(runner: runner, tmuxExecutable: executable)
  }
}

private actor BootstrapProcessRunner: ProcessRunning {
  private(set) var calls: [[String]] = []
  private var initialTargets: Set<String> = []
  private var initialProbe: CheckedContinuation<Void, Never>?
  private var bootstrapProbe: CheckedContinuation<Void, Never>?
  private var bootstrapProbeCount = 0
  private var bootstrapProbeEntered = false
  private var isReleased = false
  private var bootstrapProbeEnterWaiters: [CheckedContinuation<Void, Never>] = []
  private let initialProbeCount: Int
  private let bootstrapProbeWait: BootstrapProbeWait

  /// 実時間で再開する経路は serializesAcrossProvisioners のデッドロック回避だけに残す。
  enum BootstrapProbeWait {
    case deadlineOrNextProbe
    case untilCancelled
  }

  init(initialProbeCount: Int = 2, bootstrapProbeWait: BootstrapProbeWait = .deadlineOrNextProbe) {
    self.initialProbeCount = initialProbeCount
    self.bootstrapProbeWait = bootstrapProbeWait
  }

  func releaseAll() {
    isReleased = true
    bootstrapProbeEntered = true
    bootstrapProbeEnterWaiters.forEach { $0.resume() }
    bootstrapProbeEnterWaiters = []
    resumeBootstrapProbe()
  }

  func waitForBootstrapProbe() async {
    if bootstrapProbeEntered { return }
    await withCheckedContinuation { bootstrapProbeEnterWaiters.append($0) }
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    guard !Task.isCancelled else { throw .cancelled }
    calls.append(arguments)
    if arguments.contains("has-session"), let target = arguments.last {
      if initialTargets.insert(target).inserted {
        if initialTargets.count < initialProbeCount {
          await withCheckedContinuation { initialProbe = $0 }
        } else {
          initialProbe?.resume()
          initialProbe = nil
        }
        return .init(exitCode: 1, stdout: "", stderr: "no server running on /tmp/awt-test\n")
      }
      bootstrapProbeCount += 1
      if bootstrapProbeCount == 1 {
        bootstrapProbeEntered = true
        bootstrapProbeEnterWaiters.forEach { $0.resume() }
        bootstrapProbeEnterWaiters = []
        switch bootstrapProbeWait {
        case .deadlineOrNextProbe:
          // 修正前は後続の probe がこの待ちを解除する。直列化後は期限で進み、デッドロックを避ける。
          await withCheckedContinuation { continuation in
            bootstrapProbe = continuation
            Task {
              try? await Task.sleep(for: .seconds(1))
              resumeBootstrapProbe()
            }
          }
        case .untilCancelled:
          await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
              if Task.isCancelled || isReleased {
                continuation.resume()
              } else {
                bootstrapProbe = continuation
              }
            }
          } onCancel: {
            Task { await self.resumeBootstrapProbe() }
          }
        }
      } else {
        resumeBootstrapProbe()
      }
      guard !Task.isCancelled else { throw .cancelled }
      return .init(exitCode: 1, stdout: "", stderr: "can't find session: \(target.dropFirst())\n")
    }
    if arguments.contains("new-session") {
      return .init(exitCode: 1, stdout: "", stderr: "permission denied\n")
    }
    return .init(exitCode: 0, stdout: "", stderr: "")
  }

  private func resumeBootstrapProbe() {
    bootstrapProbe?.resume()
    bootstrapProbe = nil
  }
}
