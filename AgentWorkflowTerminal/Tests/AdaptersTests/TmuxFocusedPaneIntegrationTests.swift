import Adapters
import Foundation
import TerminalCore
import Testing

@Suite(
  "複数 window のフォーカス読み取り (設計書 §13)",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1")
)
struct TmuxFocusedPaneIntegrationTests {
  @Test("選択した pane だけにフォーカスがあり、別 window の非 active pane へ移せる")
  func followsFocusAcrossWindows() async throws {
    let socketName = uniqueSocketName("focused-pane")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let session = "focused-pane"
      let first = try await Self.createdPane(
        [
          "new-session", "-d", "-s", session, "-x", "200", "-y", "50",
          "-P", "-F", "#{pane_id}",
        ], runner: runner)
      let other = try await Self.createdPane(
        ["split-window", "-d", "-t", first.rawValue, "-P", "-F", "#{pane_id}"], runner: runner)
      let selected = try await Self.createdPane(
        ["new-window", "-d", "-t", "=\(session):", "-P", "-F", "#{pane_id}"], runner: runner)
      _ = try await Self.createdPane(
        ["split-window", "-d", "-t", selected.rawValue, "-P", "-F", "#{pane_id}"], runner: runner)
      // `select-pane` だけでは current window が動かない (`new-window -d` の window は current に
      // ならない。tmux 3.8 で実測)。
      _ = try await runner.run(arguments: [
        "select-window", "-t", selected.rawValue, ";", "select-pane", "-t", selected.rawValue,
      ])

      let before = try await Self.readPanes(session: session, runner: runner)
      #expect(before.count == 4)
      #expect(Set(before.map(\.windowID)).count == 2)
      #expect(before.filter(\.isActive).count == 2)
      #expect(before.filter(\.isFocused).map(\.paneID) == [selected])
      let target = try #require(before.first { $0.paneID == other })
      #expect(!target.isActive)
      #expect(!target.isWindowActive)

      _ = try await runner.run(arguments: [
        "select-window", "-t", other.rawValue, ";", "select-pane", "-t", other.rawValue,
      ])

      let after = try await Self.readPanes(session: session, runner: runner)
      #expect(after.count == 4)
      #expect(after.filter(\.isActive).count == 2)
      #expect(after.filter(\.isFocused).map(\.paneID) == [other])
    }
  }

  private static func createdPane(
    _ arguments: [String], runner: TmuxRunner
  ) async throws -> PaneID {
    let result = try await runner.run(arguments: arguments)
    let identifier = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    try #require(identifier.hasPrefix("%"))
    return PaneID(rawValue: identifier)
  }

  private static func readPanes(session: String, runner: TmuxRunner) async throws -> [TmuxPane] {
    let output = try await runner.run(arguments: [
      "list-panes", "-s", "-t", "=\(session)", "-F", TmuxListPanes.formatWithSummary,
    ])
    let result = TmuxListPanes.parseWithSummary(output: output.stdout)
    try #require(result.failures.isEmpty)
    return result.panes
  }
}
