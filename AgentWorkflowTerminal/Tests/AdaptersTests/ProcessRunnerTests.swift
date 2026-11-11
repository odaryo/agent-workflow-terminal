import Adapters
import Darwin
import Foundation
import Testing

@Suite("外部プロセス実行層")
struct ProcessRunnerTests {
  private let runner = FoundationProcessRunner()
  // 時間を主張しないテストの期限は安全弁であり、CI の負荷で1秒では期限切れになったため (#466)。
  private let timeout: Duration = .seconds(30)

  @Test(
    "argv の UTF-8 バイト列を保持する",
    arguments: [
      "\u{304C}", "\u{304B}\u{3099}", "\u{00E9}", "e\u{0301}",
      "\u{AC00}", "\u{1100}\u{1161}", "\u{3071}", "\u{306F}\u{309A}",
    ])
  func preservesArgumentUTF8Bytes(_ value: String) async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["-n", value],
      environment: [:],
      timeout: timeout
    )

    #expect(result.exitCode == 0)
    #expect(Array(result.stdout.utf8) == Array(value.utf8))
  }

  @Test(
    "環境変数の値の UTF-8 バイト列を保持する",
    arguments: [
      "\u{304C}", "\u{304B}\u{3099}", "\u{00E9}", "e\u{0301}",
      "\u{AC00}", "\u{1100}\u{1161}", "\u{3071}", "\u{306F}\u{309A}",
    ])
  func preservesEnvironmentValueUTF8Bytes(_ value: String) async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf %s \"$X\""],
      environment: ["X": value],
      timeout: timeout
    )

    #expect(result.exitCode == 0)
    #expect(Array(result.stdout.utf8) == Array(value.utf8))
  }

  @Test("シグナルで終了した子の終了コードはシグナル番号になる")
  func returnsSignalNumberAsExitCode() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "kill -USR1 $$"],
      environment: [:],
      timeout: timeout
    )

    #expect(result.exitCode == SIGUSR1)
  }

  @Test("子は自分の process group を持つ")
  func createsChildProcessGroup() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo $$; ps -o pgid= -p $$"],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: timeout
    )

    try #require(result.exitCode == 0)
    let lines = result.stdout.split(separator: "\n")
    try #require(lines.count == 2)
    let processID = try #require(Int(lines[0].trimmingCharacters(in: .whitespaces)))
    let processGroupID = try #require(Int(lines[1].trimmingCharacters(in: .whitespaces)))
    #expect(processID == processGroupID)
  }

  @Test("長寿命の子は短い子の出力の EOF を遅らせない", .timeLimit(.minutes(1)))
  func completesShortChildBeforeConcurrentLongChild() async throws {
    let completion = ChildCompletion()
    let longChild = Task {
      _ = try? await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["30"],
        environment: [:],
        timeout: .seconds(60)
      )
      await completion.markFinished()
    }

    do {
      // 長い子の起動に猶予を与える。検証するのは経過時間ではなく完了の順序。
      try await Task.sleep(for: .milliseconds(200))
      let result = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["hi"],
        environment: [:],
        timeout: timeout
      )
      #expect(result.exitCode == 0)
      #expect(Array(result.stdout.utf8) == Array("hi\n".utf8))
      #expect(await !completion.isFinished)
    } catch {
      longChild.cancel()
      await longChild.value
      throw error
    }
    longChild.cancel()
    await longChild.value
  }

  @Test("非ゼロ終了をエラーへ変換せず stdout と stderr を返す")
  func returnsNonzeroExitAsResult() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf output; printf error >&2; exit 7"],
      environment: [:],
      timeout: timeout
    )

    #expect(result == ProcessRunResult(exitCode: 7, stdout: "output", stderr: "error"))
  }

  @Test("指定した環境変数だけを子プロセスへ渡す")
  func replacesInheritedEnvironment() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [],
      environment: ["AWT_PROCESS_TEST": "only-value"],
      timeout: timeout
    )

    #expect(result.stdout == "AWT_PROCESS_TEST=only-value\n")
  }

  @Test("不正 UTF-8 を失敗させず置換文字として残す")
  func decodesInvalidUTF8WithoutFailure() async throws {
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf '\\377'"],
      environment: [:],
      timeout: timeout
    )

    #expect(result.stdout == "\u{FFFD}")
  }

  @Test("argv に NUL を含む場合は起動失敗にする")
  func rejectsNullInArgument() async {
    let executableURL = URL(fileURLWithPath: "/bin/echo")
    do {
      _ = try await runner.run(
        executableURL: executableURL, arguments: ["a\u{0}b"], environment: [:],
        timeout: timeout)
      Issue.record("NUL を含む引数で起動した")
    } catch {
      guard case .launchFailed(let failedURL, _) = error else {
        Issue.record("起動失敗以外のエラー: \(error)")
        return
      }
      #expect(failedURL == executableURL)
    }
  }

  @Test("環境変数の値に NUL を含む場合は起動失敗にする")
  func rejectsNullInEnvironmentValue() async {
    let executableURL = URL(fileURLWithPath: "/usr/bin/env")
    do {
      _ = try await runner.run(
        executableURL: executableURL, arguments: [], environment: ["X": "a\u{0}b"],
        timeout: timeout)
      Issue.record("NUL を含む環境変数で起動した")
    } catch {
      guard case .launchFailed(let failedURL, _) = error else {
        Issue.record("起動失敗以外のエラー: \(error)")
        return
      }
      #expect(failedURL == executableURL)
    }
  }

  @Test("起動できない実行ファイルを起動失敗として区別する")
  func reportsLaunchFailure() async {
    let executableURL = URL(fileURLWithPath: "/missing/awt/process")

    do {
      _ = try await runner.run(
        executableURL: executableURL,
        arguments: [],
        environment: [:],
        timeout: timeout
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

private actor ChildCompletion {
  private(set) var isFinished = false

  func markFinished() {
    isFinished = true
  }
}
