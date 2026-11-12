import Adapters
import Darwin
import Foundation
import Testing

@Suite("§7.2 実プロセスの出力打ち切り")
struct ProcessRunnerTruncationTests {
  private let runner = FoundationProcessRunner()

  // TERM も PIPE も無視して出力を止める子にする。`exec yes` のままだと読み口が閉じた時点の
  // SIGPIPE で終わり、猶予の後に SIGKILL を送る経路を通らない (#212 のレビューで実測 6.6 ms)。
  @Test("§7.2 上限までの連続した先頭バイトを返し、TERM を無視する子も1秒以内に停止・回収する")
  func truncatesPrefixAndReapsChild() async throws {
    let pidFile = FileManager.default.temporaryDirectory
      .appending(path: "awt-truncation-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let limit = 65_537
    let start = ContinuousClock().now
    do {
      let output = try await runner.runTruncatingAtOutputLimit(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "trap '' TERM PIPE; echo $$ > \"$1\"; /usr/bin/yes 0123456789 | /usr/bin/head -c 70000;"
            + " exec /bin/sleep 5",
          "awt-truncation", pidFile.path,
        ],
        environment: [:], timeout: .seconds(2), outputLimit: limit)
      let expected = String(String(repeating: "0123456789\n", count: 6_000).prefix(limit))
      #expect(output == .truncated(stdout: expected, stderr: "", limit: limit))
    } catch {
      Issue.record("打ち切り結果の代わりにエラー: \(error)")
    }
    let elapsed = start.duration(to: ContinuousClock().now)
    #expect(elapsed >= .milliseconds(100))
    #expect(elapsed < .seconds(1))
    let contents = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
    errno = 0
    #expect(Darwin.kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test("§7.2 上限内の終了コード・stdout・stderr は run と同じになる")
  func completesLikeRun() async throws {
    let executable = URL(fileURLWithPath: "/bin/sh")
    let arguments = ["-c", "printf out; printf err >&2; exit 7"]
    let ordinary = try await runner.run(
      executableURL: executable, arguments: arguments, environment: [:],
      timeout: .seconds(2), outputLimit: 128)
    let output = try await runner.runTruncatingAtOutputLimit(
      executableURL: executable, arguments: arguments, environment: [:],
      timeout: .seconds(2), outputLimit: 128)
    #expect(ordinary == ProcessRunResult(exitCode: 7, stdout: "out", stderr: "err"))
    #expect(output == .completed(ordinary))
  }

  @Test("§7.2 打ち切り実行も timeout では run と同じ部分出力付きエラーを投げる")
  func preservesTimeoutError() async {
    let ordinary = await timeoutError(truncating: false)
    let truncated = await timeoutError(truncating: true)
    #expect(ordinary == .timedOut(exitCode: nil, stdout: "out", stderr: "err"))
    #expect(truncated == ordinary)
  }

  private func timeoutError(truncating: Bool) async -> ProcessRunnerError? {
    let executable = URL(fileURLWithPath: "/bin/sh")
    let arguments = ["-c", "printf out; printf err >&2; exec /bin/sleep 5"]
    do {
      if truncating {
        _ = try await runner.runTruncatingAtOutputLimit(
          executableURL: executable, arguments: arguments, environment: [:],
          timeout: .milliseconds(200), outputLimit: 128)
      } else {
        _ = try await runner.run(
          executableURL: executable, arguments: arguments, environment: [:],
          timeout: .milliseconds(200), outputLimit: 128)
      }
      Issue.record("timeout 対象が成功した")
      return nil
    } catch {
      return error
    }
  }
}
