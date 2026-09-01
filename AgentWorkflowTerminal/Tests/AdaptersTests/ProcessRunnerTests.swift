import Adapters
import Darwin
import Foundation
import Testing

@Suite("Foundation.Process 実行層")
struct ProcessRunnerTests {
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

    #expect(error == .timedOut)
    #expect(elapsed < .seconds(1))
  }

  @Test("論理コア数を超える EOF 待ちでも並行性ランタイムを塞がない")
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

    try await Task.sleep(for: .milliseconds(10))
    let probe = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      environment: [:],
      timeout: .milliseconds(500)
    )
    let elapsed = start.duration(to: clock.now)
    descendantPIDs = try pidFileURLs.map(processID(from:))

    #expect(errors.count == count)
    #expect(errors.allSatisfy { $0 == .timedOut })
    #expect(probe.exitCode == 0)
    #expect(elapsed < .seconds(1))
  }

  @Test("stdout と stderr の両方をパイプ容量以上でも期限内に全バイト取得する")
  func drainsStandardOutputAndErrorConcurrently() async throws {
    let byteCount = 1_048_576
    let script = """
      dd if=/dev/zero bs=\(byteCount) count=1 2>/dev/null &
      dd if=/dev/zero bs=\(byteCount) count=1 1>&2 2>/dev/null &
      wait
      """
    let clock = ContinuousClock()
    let start = clock.now

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: [:],
      timeout: .seconds(2)
    )
    let elapsed = start.duration(to: clock.now)

    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == byteCount)
    #expect(result.stderr.utf8.count == byteCount)
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
      #expect(error == .timedOut)
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

    try await Task.sleep(for: .milliseconds(80))
    task.cancel()

    await expectTaskCancellation(task)
    try expectProcessIsGone(pidFileURL: pidFileURL)
  }

  @Test("直接の子が exit 0 後でも Task キャンセルを成功にしない")
  func cancellationWinsAfterChildExitWhilePipeRemainsOpen() async throws {
    let pidFileURL = temporaryPIDFileURL()
    var descendantPID: pid_t?
    defer {
      terminateIfRunning(descendantPID)
      try? FileManager.default.removeItem(at: pidFileURL)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let task = Task {
      try await runPipeHoldingProcess(pidFileURL: pidFileURL, timeout: .seconds(2))
    }

    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await expectTaskCancellation(task)
    let elapsed = start.duration(to: clock.now)
    descendantPID = try processID(from: pidFileURL)

    #expect(elapsed < .seconds(1))
  }

  @Test("タイムアウト停止中のキャンセルはキャンセルを優先する")
  func cancellationTakesPriorityOverTimeout() async throws {
    let pidFileURL = temporaryPIDFileURL()
    defer { try? FileManager.default.removeItem(at: pidFileURL) }
    let task = Task {
      try await runLongProcess(pidFileURL: pidFileURL, timeout: .milliseconds(50))
    }

    try await Task.sleep(for: .milliseconds(80))
    task.cancel()

    await expectTaskCancellation(task)
    try expectProcessIsGone(pidFileURL: pidFileURL)
  }

  @Test("終了境界を300回繰り返して完了済みプロセスを偽タイムアウトにしない")
  func doesNotReportFalseTimeoutAfterCompletion() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(path: "awt-process-boundary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    var falseTimeoutCount = 0

    for index in 0..<300 {
      let completedURL = directoryURL.appending(path: "completed-\(index)")
      let terminatedURL = directoryURL.appending(path: "terminated-\(index)")
      do {
        _ = try await runner.run(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: [
            "-c",
            "trap 'printf term > \"$2\"; exit 0' TERM; /bin/sleep 0.005; printf done > \"$1\"",
            "awt-boundary",
            completedURL.path,
            terminatedURL.path,
          ],
          environment: [:],
          timeout: .milliseconds(5)
        )
      } catch {
        if error == .timedOut,
          FileManager.default.fileExists(atPath: completedURL.path),
          !FileManager.default.fileExists(atPath: terminatedURL.path)
        {
          falseTimeoutCount += 1
        }
      }
    }

    #expect(falseTimeoutCount == 0)
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
      #expect(error == .timedOut)
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

  @Test("非ゼロ終了をエラーへ変換せず stdout と stderr を返す")
  func returnsNonzeroExitAsResult() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf output; printf error >&2; exit 7"],
      environment: [:],
      timeout: .seconds(1)
    )

    #expect(result == ProcessRunResult(exitCode: 7, stdout: "output", stderr: "error"))
  }

  @Test("指定した環境変数だけを子プロセスへ渡す")
  func replacesInheritedEnvironment() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [],
      environment: ["AWT_PROCESS_TEST": "only-value"],
      timeout: .seconds(1)
    )

    #expect(result.stdout == "AWT_PROCESS_TEST=only-value\n")
  }

  @Test("不正 UTF-8 を失敗させず置換文字として残す")
  func decodesInvalidUTF8WithoutFailure() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf '\\377'"],
      environment: [:],
      timeout: .seconds(1)
    )

    #expect(result.stdout == "\u{FFFD}")
  }

  @Test("起動できない実行ファイルを起動失敗として区別する")
  func reportsLaunchFailure() async {
    let executableURL = URL(fileURLWithPath: "/missing/awt/process")

    do {
      _ = try await runner.run(
        executableURL: executableURL,
        arguments: [],
        environment: [:],
        timeout: .seconds(1)
      )
      Issue.record("存在しない実行ファイルが起動した")
    } catch {
      guard case .launchFailed(let failedURL, _) = error else {
        Issue.record("起動失敗以外のエラー: \(error)")
        return
      }
      #expect(failedURL == executableURL)
    }
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

  private func temporaryPIDFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "awt-process-\(UUID().uuidString).pid")
  }

  private func processID(from pidFileURL: URL) throws -> pid_t {
    let contents = try String(contentsOf: pidFileURL, encoding: .utf8)
    return try #require(pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func expectProcessIsGone(pidFileURL: URL) throws {
    let pid = try processID(from: pidFileURL)

    errno = 0
    #expect(Darwin.kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }

  private func terminateIfRunning(_ processID: pid_t?) {
    guard let processID else { return }
    _ = Darwin.kill(processID, SIGKILL)
  }
}
