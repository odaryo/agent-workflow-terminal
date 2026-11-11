import Adapters
import Foundation
import TerminalCore
import Testing

private let isPaneSourceIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "worktree session 全 window の pane 一覧統合",
  .enabled(if: isPaneSourceIntegrationEnabled)
)
struct TmuxWorktreePaneSourceIntegrationTests {
  @Test("current window を切り替えても2つの window の pane を返す")
  func listsEveryWindowRegardlessOfCurrentWindow() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("worktree-pane-source")
    ) { runner in
      let worktree = try #require(
        WorktreeIdentity(rawValue: "/repo/.git/worktrees/multiple-windows"))
      let session = TmuxSessionName(identity: worktree)
      _ = try await runner.run(arguments: ["new-session", "-d", "-s", session.rawValue])
      _ = try await runner.run(arguments: ["new-window", "-d", "-t", "=\(session.rawValue)"])
      let source = TmuxWorktreePaneSource(runner: runner)

      _ = try await runner.run(arguments: ["select-window", "-t", "=\(session.rawValue):0"])
      let firstCurrentWindow = try await source.panes(of: worktree)
      _ = try await runner.run(arguments: ["select-window", "-t", "=\(session.rawValue):1"])
      let secondCurrentWindow = try await source.panes(of: worktree)

      #expect(firstCurrentWindow.count == 2)
      #expect(Set(firstCurrentWindow.map(\.id)) == Set(secondCurrentWindow.map(\.id)))
    }
  }

  @Test("対象 worktree の session に属する pane だけを返す")
  func excludesPanesFromOtherWorktreeSessions() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("worktree-pane-source-scope")
    ) { runner in
      let targetWorktree = try #require(
        WorktreeIdentity(rawValue: "/repo/.git/worktrees/target"))
      let otherWorktree = try #require(
        WorktreeIdentity(rawValue: "/repo/.git/worktrees/other"))
      let targetSession = TmuxSessionName(identity: targetWorktree)
      let otherSession = TmuxSessionName(identity: otherWorktree)
      for session in [targetSession, otherSession] {
        _ = try await runner.run(arguments: ["new-session", "-d", "-s", session.rawValue])
        _ = try await runner.run(arguments: ["new-window", "-d", "-t", "=\(session.rawValue)"])
      }
      let allPanes = try await runner.run(
        arguments: ["list-panes", "-a", "-F", "#{session_name} #{pane_id}"])
      let memberships = allPanes.stdout.split(separator: "\n").compactMap(PaneMembership.init)
      let expectedTarget = Set(
        memberships.filter { $0.session == targetSession.rawValue }.map(\.paneID))
      let other = Set(memberships.filter { $0.session == otherSession.rawValue }.map(\.paneID))

      let panes = try await TmuxWorktreePaneSource(runner: runner).panes(of: targetWorktree)
      let actual = Set(panes.map(\.id))

      #expect(expectedTarget.count == 2)
      #expect(other.count == 2)
      #expect(actual == expectedTarget)
      #expect(actual.isDisjoint(with: other))
    }
  }

  @Test("server はいるが session が0個のときは空配列を返す")
  func mapsSessionlessServerToEmpty() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("worktree-pane-source-sessionless")
    ) { runner in
      let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/sessionless"))
      let session = TmuxSessionName(identity: worktree)
      _ = try await runner.run(arguments: ["new-session", "-d", "-s", session.rawValue])
      _ = try await runner.run(arguments: ["set-option", "-g", "exit-empty", "off"])
      // `withServer` が起動時に作る session も消さないと、session は0個にならない。
      for name in [session.rawValue, "awt-operations"] {
        _ = try await runner.run(arguments: ["kill-session", "-t", "=\(name)"])
      }

      // server が終わっていても「server 不在 → 空」で通ってしまうので、生きていることと、
      // 生の list-panes が no current target で失敗することを先に確かめる。
      let serverPID = try await runner.run(arguments: ["display-message", "-p", "#{pid}"])
      try #require(
        Int32(serverPID.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
      do {
        _ = try await runner.run(arguments: ["list-panes", "-a", "-F", "#{pane_id}"])
        Issue.record("session が0個の server で list-panes -a が成功した")
        return
      } catch let error as TmuxRunnerError {
        try #require(
          error
            == TmuxRunnerError.commandFailed(
              exitCode: 1, stdout: "", stderr: "no current target\n"))
      } catch {
        Issue.record("list-panes -a が TmuxRunnerError 以外で失敗した: \(error)")
        return
      }

      #expect(try await TmuxWorktreePaneSource(runner: runner).panes(of: worktree).isEmpty)
    }
  }
}

private struct PaneMembership {
  let session: String
  let paneID: PaneID

  init?(line: Substring) {
    let fields = line.split(separator: " ")
    guard fields.count == 2 else { return nil }
    session = String(fields[0])
    paneID = PaneID(rawValue: String(fields[1]))
  }
}
