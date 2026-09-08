import Adapters
import Darwin
import Foundation
import Testing

@Suite("Foundation.Process 実行層")
struct ProcessRunnerTests {
  private let runner = FoundationProcessRunner()

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
}
