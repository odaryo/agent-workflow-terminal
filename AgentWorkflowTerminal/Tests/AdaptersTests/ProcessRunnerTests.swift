import Adapters
import Darwin
import Foundation
import Testing

@Suite("Foundation.Process 実行層", .serialized)
struct ProcessRunnerTests {
  private let runner = FoundationProcessRunner()

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

  @Test("標準入力を継承せず EOF で即時終了する")
  func closesStandardInput() async throws {
    // テストランナーの stdin は通常 EOF のため、書き手を保持した pipe へ一時的に差し替える。
    var descriptors: [Int32] = [-1, -1]
    try #require(Darwin.pipe(&descriptors) == 0)
    let inheritedInput = descriptors[0]
    let heldOpenWriter = descriptors[1]
    let originalInput = Darwin.dup(STDIN_FILENO)
    guard originalInput >= 0 else {
      Darwin.close(inheritedInput)
      Darwin.close(heldOpenWriter)
      try #require(originalInput >= 0)
      return
    }
    defer {
      _ = Darwin.dup2(originalInput, STDIN_FILENO)
      Darwin.close(originalInput)
      Darwin.close(inheritedInput)
      Darwin.close(heldOpenWriter)
    }
    try #require(Darwin.dup2(inheritedInput, STDIN_FILENO) >= 0)

    let timeout = Duration.seconds(2)
    let clock = ContinuousClock()
    let start = clock.now

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      environment: [:],
      timeout: timeout
    )
    let elapsed = start.duration(to: clock.now)

    #expect(result == ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    #expect(elapsed < .seconds(1))
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
}
