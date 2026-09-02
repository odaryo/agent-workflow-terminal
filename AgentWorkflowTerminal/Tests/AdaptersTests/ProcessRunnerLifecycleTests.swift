import Adapters
import Darwin
import Foundation
import Testing

@Suite("Foundation.Process 実行層の停止と上限")
struct ProcessRunnerLifecycleTests {
  private let runner = FoundationProcessRunner()

  @Test("孫が pipe を保持してもタイムアウトから1秒以内に返る")
  func timesOutWithoutWaitingForDescendantPipeEOF() async throws {
    let pidFileURL = temporaryPIDFileURL()
    var descendantPID: pid_t?
    defer {
      terminateIfRunning(descendantPID)
      try? FileManager.default.removeItem(at: pidFileURL)
    }
    let clock = ContinuousClock()
    let start = clock.now

    let error = await pipeHoldingRunError(pidFileURL: pidFileURL, timeout: .milliseconds(500))
    let elapsed = start.duration(to: clock.now)
    descendantPID = try processID(from: pidFileURL)

    #expect(
      error == .timedOut(exitCode: 0, stdout: "started\n", stderr: "")
    )
    #expect(elapsed < .seconds(1))
  }

  @Test(
    "論理コア数を超える EOF 待ちでも並行性ランタイムを塞がない",
    .timeLimit(.minutes(1))
  )
  func preservesRuntimeLivenessWithInheritedPipes() async throws {
    let count = ProcessInfo.processInfo.activeProcessorCount + 3
    let pidFileURLs = (0..<count).map { _ in temporaryPIDFileURL() }
    var descendantPIDs: [pid_t] = []
    defer {
      for pid in descendantPIDs {
        terminateIfRunning(pid)
      }
      for url in pidFileURLs {
        try? FileManager.default.removeItem(at: url)
      }
    }
    let clock = ContinuousClock()
    let start = clock.now

    let errors = await withTaskGroup(of: ProcessRunnerError?.self) { group in
      for pidFileURL in pidFileURLs {
        group.addTask {
          await pipeHoldingRunError(pidFileURL: pidFileURL, timeout: .milliseconds(500))
        }
      }

      var errors: [ProcessRunnerError?] = []
      for await error in group {
        errors.append(error)
      }
      return errors
    }

    let elapsed = start.duration(to: clock.now)
    descendantPIDs = try pidFileURLs.map(processID(from:))

    #expect(errors.count == count)
    #expect(errors.allSatisfy(isTimeout))
    #expect(elapsed < .seconds(1))
  }

  @Test("タイムアウト時は SIGTERM を無視する直接の子も終了して回収する")
  func terminatesAndReapsTimedOutProcess() async throws {
    let pidFileURL = temporaryPIDFileURL()
    defer { try? FileManager.default.removeItem(at: pidFileURL) }

    do {
      _ = try await runLongProcess(pidFileURL: pidFileURL, timeout: .milliseconds(80))
      Issue.record("タイムアウト対象のプロセスが成功した")
    } catch {
      #expect(isTimeout(error))
    }

    try expectProcessIsGone(pidFileURL: pidFileURL)
  }

  @Test("Task キャンセル時は直接の子を終了しキャンセルを返す")
  func terminatesProcessOnCancellation() async throws {
    let pidFileURL = temporaryPIDFileURL()
    defer { try? FileManager.default.removeItem(at: pidFileURL) }
    let task = Task {
      try await runLongProcess(pidFileURL: pidFileURL, timeout: .seconds(2))
    }

    // 固定時間待つと、遅いホストでは子が PID を書く前にキャンセルが走り、
    // 後段の expectProcessIsGone が読む PID ファイルが存在しない (CI で実際に発生)。
    _ = try await waitForProcessID(from: pidFileURL)
    task.cancel()

    await expectTaskCancellation(task)
    try expectProcessIsGone(pidFileURL: pidFileURL)
  }

  @Test("直接の子が exit 0 後でも Task キャンセルを成功にしない")
  func cancellationWinsAfterChildExitWhilePipeRemainsOpen() async throws {
    let parentPIDFileURL = temporaryPIDFileURL()
    let descendantPIDFileURL = temporaryPIDFileURL()
    var descendantPID: pid_t?
    defer {
      terminateIfRunning(descendantPID)
      try? FileManager.default.removeItem(at: parentPIDFileURL)
      try? FileManager.default.removeItem(at: descendantPIDFileURL)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let task = Task {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "/bin/sleep 5 & echo $! > \"$2\"; echo $$ > \"$1\"; echo started",
          "awt-cancel-after-exit",
          parentPIDFileURL.path,
          descendantPIDFileURL.path,
        ],
        environment: [:],
        timeout: .seconds(5)
      )
    }

    let parentPID = try await waitForProcessID(from: parentPIDFileURL)
    descendantPID = try await waitForProcessID(from: descendantPIDFileURL)
    try await waitForProcessToExit(parentPID)
    task.cancel()
    await expectTaskCancellation(task)
    let elapsed = start.duration(to: clock.now)

    #expect(elapsed < .seconds(1))
  }

  @Test("タイムアウト停止中のキャンセルはキャンセルを優先する")
  func cancellationTakesPriorityOverTimeout() async throws {
    let pidFileURL = temporaryPIDFileURL()
    let termFileURL = temporaryPIDFileURL()
    defer {
      try? FileManager.default.removeItem(at: pidFileURL)
      try? FileManager.default.removeItem(at: termFileURL)
    }
    let task = Task {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "trap 'echo term > \"$2\"; while :; do :; done' TERM; "
            + "echo $$ > \"$1\"; while :; do :; done",
          "awt-cancel-priority",
          pidFileURL.path,
          termFileURL.path,
        ],
        environment: [:],
        timeout: .milliseconds(100)
      )
    }

    let processID = try await waitForProcessID(from: pidFileURL)
    try await waitForFile(at: termFileURL)
    task.cancel()

    await expectTaskCancellation(task)
    try expectProcessIsGone(processID)
  }

  @Test("期限より前に完了した実行を20回繰り返して偽タイムアウトにしない")
  func doesNotReportFalseTimeoutAfterCompletion() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(path: "awt-process-boundary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let timeout = Duration.milliseconds(100)
    let timeoutSeconds = 0.1
    let deadlineMargin = 0.01
    var completedBeforeDeadlineCount = 0
    var falseTimeoutCount = 0

    for index in 0..<20 {
      let completedURL = directoryURL.appending(path: "completed-\(index)")
      let conservativeDeadline = Date().addingTimeInterval(timeoutSeconds - deadlineMargin)
      do {
        _ = try await runner.run(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: [
            "-c",
            "printf done > \"$1\"; printf output",
            "awt-boundary",
            completedURL.path,
          ],
          environment: [:],
          timeout: timeout
        )
        if try modificationDate(of: completedURL) <= conservativeDeadline {
          completedBeforeDeadlineCount += 1
        }
      } catch let error as ProcessRunnerError {
        if isTimeout(error),
          let date = try? modificationDate(of: completedURL),
          date <= conservativeDeadline
        {
          completedBeforeDeadlineCount += 1
          falseTimeoutCount += 1
        }
      } catch {
        Issue.record("ProcessRunnerError 以外のエラー: \(error)")
      }
    }

    #expect(completedBeforeDeadlineCount >= 10)
    #expect(falseTimeoutCount == 0)
  }

  @Test("出力上限で暴走するプロセスを期限内に停止する")
  func stopsProcessAtOutputLimit() async throws {
    let outputLimit = 65_536
    let pidFileURL = temporaryPIDFileURL()
    defer { try? FileManager.default.removeItem(at: pidFileURL) }
    let clock = ContinuousClock()
    let start = clock.now
    let task = Task {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c", "echo $$ > \"$1\"; exec /usr/bin/yes", "awt-output-limit", pidFileURL.path,
        ],
        environment: [:],
        timeout: .seconds(2),
        outputLimit: outputLimit
      )
    }

    let processID = try await waitForProcessID(from: pidFileURL)
    let error = await processError(from: task)
    let elapsed = start.duration(to: clock.now)

    #expect(error == .outputLimitExceeded(limit: outputLimit))
    #expect(elapsed < .seconds(1))
    try expectProcessIsGone(processID)
  }

  @Test("出力上限を指定しない実行も既定の8 MiB で暴走を止める")
  func stopsProcessAtDefaultOutputLimit() async throws {
    #expect(ProcessRunLimits.defaultOutputBytes == 8_388_608)
    let start = ContinuousClock().now

    do {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
        arguments: [],
        environment: [:],
        timeout: .seconds(1)
      )
      Issue.record("既定の上限を超えた実行が成功した")
    } catch {
      #expect(error == .outputLimitExceeded(limit: ProcessRunLimits.defaultOutputBytes))
    }
    // 既定値が実質無制限へ変わると期限まで蓄積が続くため、期限より十分短いことも確かめる。
    #expect(start.duration(to: ContinuousClock().now) < .milliseconds(500))
  }

  @Test("直接の子だけを停止するため孫は残り得る")
  func documentsGrandchildProcessLimitation() async throws {
    let grandchildPIDFileURL = temporaryPIDFileURL()
    var grandchildPID: pid_t?
    defer {
      terminateIfRunning(grandchildPID)
      try? FileManager.default.removeItem(at: grandchildPIDFileURL)
    }
    let clock = ContinuousClock()
    let start = clock.now

    do {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "trap '' TERM; /bin/sleep 30 & echo $! > \"$1\"; wait",
          "awt-grandchild",
          grandchildPIDFileURL.path,
        ],
        environment: [:],
        timeout: .milliseconds(80)
      )
      Issue.record("タイムアウト対象のプロセスが成功した")
    } catch {
      #expect(isTimeout(error))
    }
    let elapsed = start.duration(to: clock.now)
    let pid = try processID(from: grandchildPIDFileURL)
    grandchildPID = pid

    #expect(elapsed < .seconds(1))
    #expect(Darwin.kill(pid, 0) == 0)
    let psResult = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/ps"),
      arguments: ["-o", "ppid=", "-p", String(pid)],
      environment: [:],
      timeout: .milliseconds(500)
    )
    #expect(psResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
  }

  private func pipeHoldingRunError(
    pidFileURL: URL,
    timeout: Duration
  ) async -> ProcessRunnerError? {
    do {
      _ = try await runPipeHoldingProcess(pidFileURL: pidFileURL, timeout: timeout)
      return nil
    } catch {
      return error
    }
  }

  private func runPipeHoldingProcess(
    pidFileURL: URL,
    timeout: Duration
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c", "/bin/sleep 5 & echo $! > \"$1\"; echo started", "awt-pipe-holder",
        pidFileURL.path,
      ],
      environment: [:],
      timeout: timeout
    )
  }

  private func runLongProcess(
    pidFileURL: URL,
    timeout: Duration
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 5", "awt-process-test",
        pidFileURL.path,
      ],
      environment: [:],
      timeout: timeout
    )
  }

  private func expectTaskCancellation(_ task: Task<ProcessRunResult, any Error>) async {
    do {
      _ = try await task.value
      Issue.record("キャンセルしたプロセスが成功した")
    } catch let error as ProcessRunnerError {
      #expect(error == .cancelled)
    } catch {
      Issue.record("ProcessRunnerError 以外のエラー: \(error)")
    }
  }

  private func processError(
    from task: Task<ProcessRunResult, any Error>
  ) async -> ProcessRunnerError? {
    do {
      _ = try await task.value
      Issue.record("失敗するはずのプロセスが成功した")
      return nil
    } catch let error as ProcessRunnerError {
      return error
    } catch {
      Issue.record("ProcessRunnerError 以外のエラー: \(error)")
      return nil
    }
  }

  private func temporaryPIDFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "awt-process-\(UUID().uuidString).pid")
  }

  private func processID(from pidFileURL: URL) throws -> pid_t {
    let contents = try String(contentsOf: pidFileURL, encoding: .utf8)
    return try #require(pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func waitForProcessID(from pidFileURL: URL) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if let contents = try? String(contentsOf: pidFileURL, encoding: .utf8),
        let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return processID
      }
      await Task.yield()
    }
    Issue.record("PID ファイルが期限内に作られなかった: \(pidFileURL.path)")
    return try processID(from: pidFileURL)
  }

  private func waitForFile(at url: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if FileManager.default.fileExists(atPath: url.path) {
        return
      }
      await Task.yield()
    }
    Issue.record("ファイルが期限内に作られなかった: \(url.path)")
    try #require(FileManager.default.fileExists(atPath: url.path))
  }

  private func waitForProcessToExit(_ processID: pid_t) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      errno = 0
      if Darwin.kill(processID, 0) == -1, errno == ESRCH {
        return
      }
      await Task.yield()
    }
    Issue.record("直接の子が期限内に終了しなかった: \(processID)")
    try expectProcessIsGone(processID)
  }

  private func modificationDate(of url: URL) throws -> Date {
    try #require(
      url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
  }

  private func expectProcessIsGone(pidFileURL: URL) throws {
    let pid = try processID(from: pidFileURL)

    try expectProcessIsGone(pid)
  }

  private func expectProcessIsGone(_ pid: pid_t) throws {

    errno = 0
    #expect(Darwin.kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }

  private func isTimeout(_ error: ProcessRunnerError?) -> Bool {
    guard case .timedOut = error else { return false }
    return true
  }

  private func terminateIfRunning(_ processID: pid_t?) {
    guard let processID else { return }
    _ = Darwin.kill(processID, SIGKILL)
  }
}
