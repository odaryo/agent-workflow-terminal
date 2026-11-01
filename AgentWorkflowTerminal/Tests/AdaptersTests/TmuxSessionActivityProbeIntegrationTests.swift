import Adapters
import Foundation
import TerminalCore
import Testing

private let isSessionActivityIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "session を閉じる前の活動状態の実 tmux 統合 (設計書 §3.1)",
  .enabled(if: isSessionActivityIntegrationEnabled)
)
struct TmuxSessionActivityProbeIntegrationTests {
  @Test(
    "pane のプロセス起動を確認してから公開 probe で判定する",
    arguments: ActivityPaneCommand.allCases)
  func probesLivePane(command: ActivityPaneCommand) async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("session-activity")
    ) { runner in
      let key = try sessionKey(identity: "/repo/.git/worktrees/activity", index: 2)
      let name = TmuxSessionName(key: key)
      _ = try await runner.run(
        arguments: ["new-session", "-d", "-s", name.rawValue] + command.arguments)
      try await waitForCommand(runner: runner, session: name, command: command)
      let probe = TmuxSessionActivityProbe(
        tmuxRunner: runner, processRunner: FoundationProcessRunner())

      #expect(await probe.activity(of: key) == command.expected)
    }
  }

  @Test("存在しない Project Root session は undetermined")
  func missingSessionIsUndetermined() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("session-activity-missing")
    ) { runner in
      let key = try sessionKey(identity: "/repo/.git")
      let probe = TmuxSessionActivityProbe(
        tmuxRunner: runner, processRunner: FoundationProcessRunner())

      #expect(await probe.activity(of: key) == .undetermined)
    }
  }

  @Test("remain-on-exit で死んだ pane だけを残した session は shellOnly")
  func deadPaneOnlyIsShellOnly() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("session-activity-dead")
    ) { runner in
      let key = try sessionKey(identity: "/repo/.git/worktrees/dead-activity")
      let name = TmuxSessionName(key: key)
      // 作成後に設定すると true が先に終了して session ごと消えるため、作成前に設定する。
      _ = try await runner.run(arguments: ["set-option", "-g", "remain-on-exit", "on"])
      _ = try await runner.run(
        arguments: ["new-session", "-d", "-s", name.rawValue, "/usr/bin/true"])
      try await waitForPane(runner: runner, session: name) { _, isDead in isDead }
      let probe = TmuxSessionActivityProbe(
        tmuxRunner: runner, processRunner: FoundationProcessRunner())

      #expect(await probe.activity(of: key) == .shellOnly)
    }
  }

  @Test("current window が shell だけでも別 window の sleep を running と判定する")
  func probesAllWindows() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("session-activity-windows")
    ) { runner in
      let key = try sessionKey(identity: "/repo/.git/worktrees/activity-windows")
      let name = TmuxSessionName(key: key)
      try await withSessions(runner: runner, names: [name]) {
        _ = try await runner.run(
          arguments: ["new-session", "-d", "-s", name.rawValue, "/bin/sh"])
        try await waitForCommand(runner: runner, session: name, command: .shellOnly)
        _ = try await runner.run(
          arguments: ["new-window", "-t", "=\(name.rawValue):1", "/bin/sleep", "600"])
        _ = try await runner.run(arguments: ["select-window", "-t", "=\(name.rawValue):0"])
        try await waitForCommand(runner: runner, session: name, command: .directSleep)
        let probe = TmuxSessionActivityProbe(
          tmuxRunner: runner, processRunner: FoundationProcessRunner())

        #expect(await probe.activity(of: key) == .running)
      }
    }
  }

  @Test("別 session の同名 window より対象 session の sleep を判定する")
  func sessionTargetDoesNotResolveToWindowName() async throws {
    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("session-activity-collision")
    ) { runner in
      let key = try sessionKey(identity: "/repo/.git/worktrees/activity-collision")
      let name = TmuxSessionName(key: key)
      let otherKey = try sessionKey(identity: "/repo/.git/worktrees/activity-other")
      let otherName = TmuxSessionName(key: otherKey)
      try await withSessions(runner: runner, names: [otherName, name]) {
        _ = try await runner.run(
          arguments: ["new-session", "-d", "-s", name.rawValue, "/bin/sleep", "600"])
        try await waitForCommand(runner: runner, session: name, command: .directSleep)
        _ = try await runner.run(
          arguments: ["new-session", "-d", "-s", otherName.rawValue, "/bin/sh"])
        try await waitForCommand(runner: runner, session: otherName, command: .shellOnly)
        _ = try await runner.run(
          arguments: [
            "set-window-option", "-t", "=\(otherName.rawValue):0", "automatic-rename", "off",
          ])
        _ = try await runner.run(
          arguments: ["rename-window", "-t", "=\(otherName.rawValue):0", name.rawValue])
        let probe = TmuxSessionActivityProbe(
          tmuxRunner: runner, processRunner: FoundationProcessRunner())

        #expect(await probe.activity(of: key) == .running)
      }
    }
  }

  private func sessionKey(identity: String, index: Int = 1) throws -> TerminalSessionKey {
    let worktree = try #require(WorktreeIdentity(rawValue: identity))
    return try #require(TerminalSessionKey(identity: worktree, index: index))
  }

  private func withSessions(
    runner: TmuxRunner, names: [TmuxSessionName], body: () async throws -> Void
  ) async throws {
    let result: Result<Void, any Error>
    do {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    for name in names {
      do {
        _ = try await runner.run(arguments: ["kill-session", "-t", "=\(name.rawValue)"])
      } catch {
        Issue.record("session の後始末に失敗: \(name.rawValue): \(error)")
      }
    }
    try result.get()
  }

  private func waitForCommand(
    runner: TmuxRunner, session: TmuxSessionName, command: ActivityPaneCommand
  ) async throws {
    try await waitForPane(runner: runner, session: session) { pid, isDead in
      guard !isDead, let pid else { return false }
      let output = try await FoundationProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/ps"),
        arguments: ["-Ao", "pid=,ppid=,comm="], environment: ["LC_ALL": "C"],
        timeout: .seconds(10))
      try #require(output.exitCode == 0)
      let rows = output.stdout.split(separator: "\n").map {
        $0.split(maxSplits: 2, whereSeparator: \.isWhitespace)
      }
      let rootReady = rows.contains {
        $0.count == 3 && Int32($0[0]) == pid
          && $0[2].split(separator: "/").last == command.rootName
      }
      let childReady = rows.contains {
        $0.count == 3 && Int32($0[1]) == pid
          && $0[2].split(separator: "/").last == "sleep"
      }
      return rootReady && (!command.requiresChild || childReady)
    }
  }

  private func waitForPane(
    runner: TmuxRunner, session: TmuxSessionName,
    condition: (Int32?, Bool) async throws -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    var lastOutput = ""
    repeat {
      let result = try await runner.run(
        arguments: [
          "list-panes", "-s", "-t", "=\(session.rawValue):", "-F", "#{pane_pid} #{pane_dead}",
        ])
      lastOutput = result.stdout
      for line in result.stdout.split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        try #require(fields.count == 2)
        try #require(fields[1] == "0" || fields[1] == "1")
        let pid = Int32(fields[0])
        if fields[1] == "0" {
          try #require(pid != nil && (pid ?? 0) > 0)
        }
        if try await condition(pid, fields[1] == "1") { return }
      }
      try await Task.sleep(for: .milliseconds(20))
    } while clock.now < deadline
    throw ActivityPaneWaitError.conditionNotMet(lastOutput)
  }
}

enum ActivityPaneCommand: String, Sendable, CaseIterable {
  case shellOnly
  case shellWithSleep
  case directSleep

  var arguments: [String] {
    switch self {
    case .shellOnly: ["/bin/sh"]
    case .shellWithSleep: ["/bin/sh", "-c", "sleep 600; true"]
    case .directSleep: ["/bin/sleep", "600"]
    }
  }

  var rootName: Substring {
    switch self {
    case .shellOnly, .shellWithSleep: "sh"
    case .directSleep: "sleep"
    }
  }

  var requiresChild: Bool { self == .shellWithSleep }

  var expected: TerminalSessionActivity {
    switch self {
    case .shellOnly: .shellOnly
    case .shellWithSleep, .directSleep: .running
    }
  }
}

private enum ActivityPaneWaitError: Error {
  case conditionNotMet(String)
}
