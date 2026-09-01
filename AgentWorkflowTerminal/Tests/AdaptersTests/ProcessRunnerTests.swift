import Adapters
import Darwin
import Foundation
import Testing

@Suite("Foundation.Process 実行層")
struct ProcessRunnerTests {
  private let runner = FoundationProcessRunner()

  @Test("stdout と stderr の両方をパイプ容量以上でも全バイト取得する")
  func drainsStandardOutputAndErrorConcurrently() async throws {
    let byteCount = 1_048_576
    let script = """
      dd if=/dev/zero bs=\(byteCount) count=1 2>/dev/null &
      dd if=/dev/zero bs=\(byteCount) count=1 1>&2 2>/dev/null &
      wait
      """

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: [:],
      timeout: .seconds(2)
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == byteCount)
    #expect(result.stderr.utf8.count == byteCount)
  }

  @Test("タイムアウト時は子プロセスを終了して回収する")
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

  @Test("Task キャンセル時は子プロセスを終了しキャンセルを返す")
  func terminatesProcessOnCancellation() async throws {
    let pidFileURL = temporaryPIDFileURL()
    defer { try? FileManager.default.removeItem(at: pidFileURL) }
    let task = Task {
      try await runLongProcess(pidFileURL: pidFileURL, timeout: .seconds(2))
    }

    try await Task.sleep(for: .milliseconds(80))
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("キャンセルしたプロセスが成功した")
    } catch let error as ProcessRunnerError {
      #expect(error == .cancelled)
    } catch {
      Issue.record("ProcessRunnerError 以外のエラー: \(error)")
    }
    try expectProcessIsGone(pidFileURL: pidFileURL)
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

  private func temporaryPIDFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "awt-process-\(UUID().uuidString).pid")
  }

  private func expectProcessIsGone(pidFileURL: URL) throws {
    let contents = try String(contentsOf: pidFileURL, encoding: .utf8)
    let pid = try #require(pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)))

    errno = 0
    #expect(Darwin.kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }
}
