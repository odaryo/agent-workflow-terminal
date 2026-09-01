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
    let executableURL = try #require(
      TmuxRunner.defaultExecutableCandidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    defer {
      if let serverPID {
        _ = Darwin.kill(serverPID, SIGTERM)
      }
      try? FileManager.default.removeItem(at: socketURL)
    }
    let runner = try TmuxRunner(
      socketName: socketName,
      processRunner: FoundationProcessRunner(),
      executableCandidates: [executableURL]
    )

    var testError: (any Error)?
    do {
      _ = try await runner.run(arguments: ["new-session", "-d", "-s", sessionName])
      let server = try await runner.run(arguments: ["display-message", "-p", "#{pid}"])
      serverPID = pid_t(server.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      #expect(serverPID != nil)

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

  private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }
}
