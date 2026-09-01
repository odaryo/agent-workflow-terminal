import Adapters
import Foundation
import Testing

private let isTmuxIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "隔離 tmux server との統合",
  .enabled(if: isTmuxIntegrationEnabled)
)
struct TmuxRunnerIntegrationTests {
  private let socketName = "awt-integration"
  private let sessionName = "awt-integration-session"

  @Test("専用 server で session 作成・pane 取得・非ゼロ終了を確認する")
  func runsAgainstIsolatedServer() async throws {
    let runner = try TmuxRunner(
      socketName: socketName,
      processRunner: FoundationProcessRunner()
    )
    await killServer(using: runner)

    var testError: (any Error)?
    do {
      _ = try await runner.run(arguments: ["new-session", "-d", "-s", sessionName])
      let panes = try await runner.run(
        arguments: ["list-panes", "-t", sessionName, "-F", "#{pane_id}"])
      #expect(panes.stdout.hasPrefix("%"))

      do {
        _ = try await runner.run(arguments: ["awt-command-that-does-not-exist"])
        Issue.record("存在しない tmux サブコマンドが成功した")
      } catch let error {
        guard case .commandFailed(let exitCode, let stderr) = error else {
          Issue.record("tmux の非ゼロ終了以外のエラー: \(error)")
          throw error
        }
        #expect(exitCode != 0)
        #expect(!stderr.isEmpty)
      }
    } catch {
      testError = error
    }

    await killServer(using: runner)
    if let testError {
      throw testError
    }
  }

  private func killServer(using runner: TmuxRunner) async {
    _ = try? await runner.run(arguments: ["kill-server"], timeout: .seconds(1))
  }
}
