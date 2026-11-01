import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("Close が接尾辞付きの session を終わらせる (§3.4、#455)")
struct CloseNumberedSessionTests {
  // 最初のタブを閉じると番号 1 の session は終わる (§3.1) ので、Close の前によく起きる状態。
  @Test("番号 1 が既に無くても、残っている接尾辞付きの session を終わらせる")
  func terminatesNumberedSessionsAfterPrimaryIsGone() async throws {
    let base = "awt-feature-a-219261c3"
    let harness = try WorktreeCloseHarness(
      tmux: .init { arguments in
        if arguments.contains("list-sessions") { return stubSuccess(stdout: "\(base)-2\n") }
        return arguments.last == "=\(base)"
          ? stubFailure(stderr: "can't find session: \(base)\n") : stubSuccess()
      })

    let outcome = try await harness.run(try harness.plan(.terminateSession(.keepWorktree)))

    #expect(
      outcome == WorktreeCloseOutcome(completed: [.terminateSession], failure: nil, skipped: []))
    #expect(
      await harness.tmux.invocations.map(\.arguments) == [
        ["-u", "-L", "awt-test", "list-sessions", "-F", "#{session_name}"],
        ["-u", "-L", "awt-test", "kill-session", "-t", "=\(base)"],
        ["-u", "-L", "awt-test", "kill-session", "-t", "=\(base)-2"],
      ])
  }
}
