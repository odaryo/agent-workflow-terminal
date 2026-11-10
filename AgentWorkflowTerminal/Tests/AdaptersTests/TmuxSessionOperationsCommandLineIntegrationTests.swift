import Adapters
import Foundation
import TerminalCore
import Testing

@Suite(
  "隔離 tmux server での1行コマンド入力 (設計書 §3.1)",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1")
)
struct TmuxSessionCommandLineIntegrationTests {
  private static let commandLines = [
    "plain", "end;", "end;;;", "end\\", "end\\;", "end\\\\;",
    "#{host} ##", "middle ; semicolon", "日本語 e\u{301}", "-n x", "space  ",
  ]

  @Test("create した session の active pane に UTF-8 と CR がそのまま届く")
  func sendsExactCommandLineBytes() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp")
      .appending(path: "awt-command-line-bytes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("command-line-bytes")
    ) { runner in
      let received = directory.appending(path: "bytes")
      let ready = directory.appending(path: "ready")
      let startup = directory.appending(path: "receiver.sh")
      // raw 設定前に送ると端末の改行変換が入り得るため、設定後に受信 pane を通知する。
      let script = #"""
        set -e
        stty raw -echo
        printf '%s\n' "$TMUX_PANE" > '\#(ready.path)'
        exec cat > '\#(received.path)'
        """#
      try Data(script.utf8).write(to: startup)
      _ = try await runner.run(
        arguments: ["set-option", "-g", "default-command", "/bin/sh '\(startup.path)'"])
      let identity = try #require(WorktreeIdentity(rawValue: directory.path))
      let name = TmuxSessionName(identity: identity)
      let operations = TmuxSessionOperations(runner: runner)
      try await operations.create(session: name, workingDirectory: directory.path)
      let pane = try await runner.run(
        arguments: ["display-message", "-p", "-t", "=\(name.rawValue):", "#{pane_id}"]
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      try #require(pane.hasPrefix("%"))
      let readyPane = try await waitForData(minimumCount: pane.utf8.count + 1, at: ready)
      try #require(readyPane == Data((pane + "\n").utf8))
      var expected = Data()

      for commandLine in Self.commandLines {
        try await operations.typeCommandLine(commandLine, into: name)

        expected.append(contentsOf: commandLine.utf8)
        expected.append(0x0D)
        let actual = try await waitForData(minimumCount: expected.count, at: received)
        #expect(actual == expected)
      }
      try await Task.sleep(for: .milliseconds(300))
      #expect(try Data(contentsOf: received) == expected)
    }
  }

  @Test(
    "create した session の current window の active pane で各コマンドを1回だけ実行する",
    arguments: [false, true]
  )
  func executesCommandLineOnce(selectsAnotherPane: Bool) async throws {
    let directory = URL(fileURLWithPath: "/private/tmp")
      .appending(path: "awt-command-line-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await IsolatedTmuxServer.withServer(
      socketName: uniqueSocketName("command-line")
    ) { runner in
      try await configureShell(runner, directory: directory)
      let identity = try #require(WorktreeIdentity(rawValue: directory.path))
      let name = TmuxSessionName(identity: identity)
      let operations = TmuxSessionOperations(runner: runner)
      try await operations.create(session: name, workingDirectory: directory.path)
      let target = "=\(name.rawValue):"
      let pane: String
      if selectsAnotherPane {
        _ = try await runner.run(arguments: ["new-window", "-t", target])
        pane = try await runner.run(
          arguments: ["split-window", "-h", "-t", target, "-P", "-F", "#{pane_id}"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        let panes = try await runner.run(
          arguments: ["list-panes", "-s", "-t", "=\(name.rawValue)", "-F", "#{pane_id}"]
        ).stdout.split(separator: "\n")
        try #require(panes.count == 1)
        pane = String(try #require(panes.first))
      }
      try #require(pane.hasPrefix("%"))
      let markers = directory.appending(path: "markers")
      let executedPanes = directory.appending(path: "panes")
      var expectedMarkers = ""
      var expectedPanes = ""

      for suffix in Self.commandLines {
        let marker = UUID().uuidString
        let commandLine =
          "-agent '\(marker)' '\(markers.path)' '\(executedPanes.path)'; # \(suffix)"

        try await operations.typeCommandLine(commandLine, into: name)

        expectedMarkers += marker + "\n"
        expectedPanes += pane + "\n"
        let actualMarkers = try await waitForData(
          minimumCount: expectedMarkers.utf8.count, at: markers)
        let actualPanes = try await waitForData(
          minimumCount: expectedPanes.utf8.count, at: executedPanes)
        #expect(actualMarkers == Data(expectedMarkers.utf8))
        #expect(actualPanes == Data(expectedPanes.utf8))
      }
      try await Task.sleep(for: .milliseconds(300))
      #expect(try Data(contentsOf: markers) == Data(expectedMarkers.utf8))
      #expect(try Data(contentsOf: executedPanes) == Data(expectedPanes.utf8))
    }
  }

  private func configureShell(_ runner: TmuxRunner, directory: URL) async throws {
    let startup = directory.appending(path: "bashrc")
    let script = #"""
      unset HISTFILE
      function -agent {
        printf '%s\n' "$1" >> "$2"
        printf '%s\n' "$TMUX_PANE" >> "$3"
      }
      PS1='awt> '
      PS2=
      """#
    try Data(script.utf8).write(to: startup)
    _ = try await runner.run(arguments: ["set-option", "-g", "default-shell", "/bin/bash"])
    _ = try await runner.run(
      arguments: [
        "set-option", "-g", "default-command",
        "/bin/bash --noprofile --rcfile '\(startup.path)' -i",
      ])
  }

  private func waitForData(minimumCount: Int, at url: URL) async throws -> Data {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      if let data = try? Data(contentsOf: url), data.count >= minimumCount {
        return data
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: url.path), "期限内に受信ファイルが作られなかった")
    return try Data(contentsOf: url)
  }
}
