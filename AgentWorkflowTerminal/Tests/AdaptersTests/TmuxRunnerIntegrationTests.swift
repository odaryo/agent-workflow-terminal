import Adapters
import Darwin
import Foundation
import Testing

private let isTmuxIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "隔離 tmux server との統合",
  .enabled(if: isTmuxIntegrationEnabled)
)
struct TmuxRunnerIntegrationTests {
  private let sessionName = "awt-integration-session"

  @Test("専用 server で session 作成・pane 取得・非ゼロ終了を確認する")
  func runsAgainstIsolatedServer() async throws {
    let socketName = "awt-integration-\(ProcessInfo.processInfo.processIdentifier)"
    let socketURL = integrationSocketURL(socketName: socketName)
    var serverPID: pid_t?
    var serverWasStopped = false
    let executableURL = try #require(
      TmuxRunner.defaultExecutableCandidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    defer {
      if let serverPID {
        serverWasStopped = terminateServer(serverPID)
      }
      removeSocketIfStopped(serverWasStopped, socketURL: socketURL)
    }
    let runner = try TmuxRunner(
      socketName: socketName,
      processRunner: FoundationProcessRunner(),
      executableCandidates: [executableURL]
    )

    var testError: (any Error)?
    do {
      let server = try await runner.run(
        arguments: ["new-session", "-d", "-s", sessionName, "-P", "-F", "#{pid}"])
      serverPID = pid_t(server.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      try #require(
        (serverPID ?? 0) > 0, "PID が正数でない stdout: \(String(reflecting: server.stdout))")

      let socketPath = try await runner.run(
        arguments: ["display-message", "-p", "#{socket_path}"])
      #expect(
        canonicalPath(socketPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
          == canonicalPath(socketURL.path)
      )

      let panes = try await runner.run(
        arguments: ["list-panes", "-t", sessionName, "-F", "#{pane_id}"])
      #expect(panes.stdout.hasPrefix("%"))

      do {
        _ = try await runner.run(arguments: ["awt-command-that-does-not-exist"])
        Issue.record("存在しない tmux サブコマンドが成功した")
      } catch let error {
        guard case .commandFailed(let exitCode, let stdout, let stderr) = error else {
          Issue.record("tmux の非ゼロ終了以外のエラー: \(error)")
          throw error
        }
        #expect(exitCode != 0)
        #expect(stdout.isEmpty)
        #expect(!stderr.isEmpty)
      }
    } catch {
      testError = error
    }

    if (try? await runner.run(arguments: ["kill-server"], timeout: .seconds(1))) != nil {
      serverWasStopped = true
      serverPID = nil
    }
    if let testError {
      throw testError
    }
  }

  private func integrationSocketURL(socketName: String) -> URL {
    let socketParent = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/private/tmp"
    return URL(fileURLWithPath: socketParent)
      .appending(path: "tmux-\(getuid())")
      .appending(path: socketName)
  }

  private func removeSocketIfStopped(_ serverWasStopped: Bool, socketURL: URL) {
    guard serverWasStopped else {
      // テストの成否は変えない。残置は設計どおりだが、手で片付ける必要があることは伝える。
      FileHandle.standardError.write(
        Data(
          "警告: tmux server の停止を確認できませんでした。socket を残します: \(socketURL.path)\n"
            .utf8))
      return
    }
    try? FileManager.default.removeItem(at: socketURL)
  }

  /// 戻り値は「停止を確認できたか」であり、呼び出し側はこれが false のとき socket を残す。
  /// 生きている server の socket を消すと `-L` から到達できない orphan になり、
  /// 手で片付けることすらできなくなるため、stale な socket が残る方を選ぶ。
  private func terminateServer(_ serverPID: pid_t) -> Bool {
    // 0 や負値は kill(2) では「プロセスグループ」「全プロセス」の意味になり、
    // テストランナー自身を撃つ。外部 CLI 由来の値なので syscall へ渡す前に弾く。
    guard serverPID > 0 else { return false }
    guard Darwin.kill(serverPID, SIGTERM) == 0 else { return errno == ESRCH }

    let clock = ContinuousClock()
    // SIGTERM から終了までは実測で約 13ms。無反応な server を待ち続けないための上界として
    // その約40倍を取る。errno は必ず「失敗した syscall の直後」だけを読む (短絡に依存)。
    let deadline = clock.now.advanced(by: .milliseconds(500))
    while clock.now < deadline {
      guard Darwin.kill(serverPID, 0) == 0 else { return errno == ESRCH }
      // defer からは await できないため Task.sleep を使えない (§5.3 の非同期 I/O 方針の例外)。
      // 塞ぐのは kill-server が失敗した異常系のみ。
      Darwin.usleep(10_000)
    }
    return Darwin.kill(serverPID, 0) != 0 && errno == ESRCH
  }

  private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }
}
