import Adapters
import Darwin
import Foundation
import TerminalCore
import Testing

@Suite("tmux list-panes 出力のパース")
struct TmuxListPanesTests {

  @Test("フォーマットは pane 状態の取得に必要な14フィールドを Unit Separator で区切る")
  func formatContainsRequiredFields() {
    #expect(
      TmuxListPanes.format
        // tmux へ渡す format と1文字も違わないことの検証。分割・連結で組み立てると
        // フォーマットの再実装になり検証の意味が消えるため、原文のまま1行で置く。
        // swiftlint:disable:next line_length
        == "#{pane_id}\u{1F}#{session_name}\u{1F}#{window_index}\u{1F}#{window_id}\u{1F}#{pane_index}\u{1F}#{pane_pid}\u{1F}#{pane_active}\u{1F}#{s/\\\\/\\\\\\\\/:pane_current_command}\u{1F}#{pane_dead}\u{1F}#{pane_dead_status}\u{1F}#{pane_dead_signal}\u{1F}#{s/\\\\/\\\\\\\\/:pane_tty}\u{1F}#{s/\\\\/\\\\\\\\/:pane_current_path}\u{1F}#{s/\\\\/\\\\\\\\/:pane_title}"
    )
  }

  @Test("区切り表現と日本語・絵文字を含む path と title を真の値へ戻す")
  func parsesEscapedPathFixture() throws {
    // 採取: tmux 3.4 / socket `awt-issue12-fixtures-28020`。
    // `mkdir '/private/tmp/awt-issue12-fixtures-pGiL0f/dir\037x-日本語🚀'`
    // `ln -s /bin/sleep '/private/tmp/awt-issue12-fixtures-pGiL0f/cmd\037x'`
    // `tmux -u -L awt-issue12-fixtures-28020 new-session -d -s path-fixture -c <上記path>
    //   "printf '\033]2;題名🚀\007'; exec '/private/tmp/awt-issue12-fixtures-pGiL0f/cmd\037x' 120"`
    // `tmux -u -L awt-issue12-fixtures-28020 list-panes -t %0 -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-escaped-path.txt")
    )
    let pane = try #require(result.panes.first)

    #expect(result.failures.isEmpty)
    #expect(result.panes.count == 1)
    #expect(pane.paneID == PaneID(rawValue: "%0"))
    #expect(pane.sessionName == "path-fixture")
    #expect(pane.windowIndex == 0)
    #expect(pane.windowID == "@0")
    #expect(pane.paneIndex == 0)
    #expect(pane.panePID == 28_027)
    #expect(pane.isActive)
    #expect(pane.currentCommand == "sleep")
    #expect(pane.termination == nil)
    #expect(pane.tty == "/dev/ttys018")
    #expect(
      pane.currentPath
        == "/private/tmp/awt-issue12-fixtures-pGiL0f/dir\\037x-日本語🚀"
    )
    #expect(pane.title == "題名🚀")
  }

  @Test("$ とバックスラッシュを含む session 名を tmux の target 形式へ戻す")
  func decodesDollarEscapeInSessionNameFixture() throws {
    // 採取: `tmux -u -L awt-issue12-fixtures-28020 new-session -d
    //   -s 'fixture$dol\bs' 'sleep 120'`
    // `tmux -u -L awt-issue12-fixtures-28020 list-panes -t %1 -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-dollar-session.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(result.panes.first?.sessionName == "fixture\\$dol\\\\bs")
  }

  @Test("非ゼロ終了した dead pane の終了コードと空の current path を保持する")
  func parsesExitedPaneFixture() throws {
    // 採取: `tmux -u -L awt-issue12-fixtures-28020 new-session -d -s dead-fixture
    //   'sh -c "sleep 1; exit 23"'`
    // `tmux -u -L awt-issue12-fixtures-28020 set-option -w -t %2 remain-on-exit on`
    // `tmux -u -L awt-issue12-fixtures-28020 list-panes -t %2 -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-dead.txt")
    )
    let pane = try #require(result.panes.first)

    #expect(result.failures.isEmpty)
    #expect(pane.panePID == 28_032)
    #expect(pane.termination == .exited(status: 23))
    #expect(pane.currentPath.isEmpty)
    #expect(pane.snapshot.isDead)
  }

  @Test("シグナル終了した dead pane を終了コードと混同しない")
  func parsesSignaledPaneFixture() throws {
    // 採取: `tmux -u -L awt-issue12-fixtures-28020 new-session -d -s signal-fixture
    //   'sh -c "sleep 1; kill -TERM $$"'`
    // `tmux -u -L awt-issue12-fixtures-28020 set-option -w -t %3 remain-on-exit on`
    // `tmux -u -L awt-issue12-fixtures-28020 list-panes -t %3 -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-dead-signal.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(result.panes.first?.termination == .signaled("term"))
    #expect(result.panes.first?.snapshot.isDead == true)
  }

  @Test("生フィールドはバックスラッシュと $ の符号化を順序を問わず復号する")
  func decodesRawFieldsRegardlessOfOrder() throws {
    let pane = try TmuxListPanes.parse(
      line: encodedLine(
        sessionName: #"ses\\$dol\\bs"#,
        currentCommand: #"cmd\\037x\$cash"#,
        tty: #"/dev/tty\\037x"#,
        currentPath: #"/tmp/dir\\037x"#,
        title: #"before\\037after"#
      )
    )

    #expect(pane.sessionName == #"ses\$dol\\bs"#)
    #expect(pane.currentCommand == #"cmd\037x$cash"#)
    #expect(pane.tty == #"/dev/tty\037x"#)
    #expect(pane.currentPath == #"/tmp/dir\037x"#)
    #expect(pane.title == #"before\037after"#)
  }

  @Test("連続するバックスラッシュの末尾にある $ だけから tmux の挿入分を除く")
  func decodesInsertedDollarEscapeWithoutDamagingBackslashes() throws {
    let pane = try TmuxListPanes.parse(
      line: encodedLine(currentCommand: #"\\\$"#)
    )

    #expect(pane.currentCommand == #"\$"#)
  }

  @Test("空白と一般的な記号をフィールド内に保持する")
  func preservesSpacesAndSymbols() throws {
    let pane = try TmuxListPanes.parse(
      line: encodedLine(
        sessionName: "session alpha [&]",
        currentCommand: "agent worker [&]"
      )
    )

    #expect(pane.sessionName == "session alpha [&]")
    #expect(pane.currentCommand == "agent worker [&]")
  }

  @Test("生フィールドの TAB と LF を parse(line:) で保持する")
  func preservesTabAndLineFeedInRawField() throws {
    let pane = try TmuxListPanes.parse(
      line: encodedLine(currentCommand: "cmd\\\\sl\nash\tz")
    )

    #expect(pane.currentCommand == "cmd\\sl\nash\tz")
  }

  @Test("tmux の LF だけをレコード区切りとして U+2028 はフィールド内に保持する")
  func onlyLineFeedSeparatesRecords() {
    let sessionName = "before\u{2028}after"
    let result = TmuxListPanes.parse(
      output: encodedLine(sessionName: sessionName) + "\n"
    )

    #expect(result.failures.isEmpty)
    #expect(result.panes.first?.sessionName == sessionName)
  }

  @Test("live pane から PaneSnapshot を作る")
  func makesPaneSnapshot() throws {
    let pane = try TmuxListPanes.parse(
      line: encodedLine(
        paneID: "%9",
        panePID: "4242",
        currentCommand: "codex",
        tty: "/dev/ttys009",
        currentPath: "/worktree",
        title: "agent"
      )
    )

    #expect(
      pane.snapshot
        == PaneSnapshot(
          id: PaneID(rawValue: "%9"),
          processID: 4242,
          tty: "/dev/ttys009",
          currentCommand: "codex",
          currentPath: "/worktree",
          title: "agent",
          isDead: false
        )
    )
  }

  @Test("空の出力は pane が無いものとして空配列にする")
  func emptyOutputProducesNoPanes() {
    let result = TmuxListPanes.parse(output: "")

    #expect(result.panes.isEmpty)
    #expect(result.failures.isEmpty)
  }

  @Test("1行の異常があっても正常 pane と行番号・原文・エラーを両方返す")
  func preservesPartialSuccessAndLineFailure() {
    let validFirst = encodedLine(paneID: "%0")
    let invalid = encodedLine(paneID: "%1", paneActive: "2")
    let validLast = encodedLine(paneID: "%2")

    let result = TmuxListPanes.parse(
      output: [validFirst, invalid, validLast].joined(separator: "\n"))

    #expect(result.panes.map(\.paneID) == [PaneID(rawValue: "%0"), PaneID(rawValue: "%2")])
    #expect(
      result.failures
        == [
          TmuxListPanesParseFailure(
            lineNumber: 2,
            line: invalid,
            error: .invalidPaneActive("2")
          )
        ]
    )
  }

  @Test("pane_dead は0か1だけを受け入れる")
  func rejectsInvalidDeadValue() {
    #expect(throws: TmuxListPanesParseError.invalidPaneDead("2")) {
      try TmuxListPanes.parse(line: encodedLine(paneDead: "2"))
    }
  }

  @Test("dead pane は終了コードかシグナルの片方を必要とする")
  func rejectsMissingDeadTermination() {
    #expect(
      throws: TmuxListPanesParseError.invalidPaneTermination(status: "", signal: "")
    ) {
      try TmuxListPanes.parse(line: encodedLine(paneDead: "1"))
    }
  }

  @Test("live pane は終了情報を持てない")
  func rejectsTerminationOnLivePane() {
    #expect(
      throws: TmuxListPanesParseError.invalidPaneTermination(status: "23", signal: "")
    ) {
      try TmuxListPanes.parse(line: encodedLine(deadStatus: "23"))
    }
  }

  @Test("終了コードは非負整数だけを受け入れる")
  func rejectsInvalidDeadStatus() {
    #expect(throws: TmuxListPanesParseError.invalidPaneDeadStatus("signal")) {
      try TmuxListPanes.parse(line: encodedLine(paneDead: "1", deadStatus: "signal"))
    }
  }

  @Test("フィールド数が14でなければ拒否する")
  func rejectsInvalidFieldCount() {
    #expect(throws: TmuxListPanesParseError.invalidFieldCount(actual: 2)) {
      try TmuxListPanes.parse(line: "%0\\037session")
    }
  }

  @Test("pane_active は0か1だけを受け入れる")
  func rejectsInvalidActiveValue() {
    #expect(throws: TmuxListPanesParseError.invalidPaneActive("2")) {
      try TmuxListPanes.parse(line: encodedLine(paneActive: "2"))
    }
  }

  private func encodedLine(
    paneID: String = "%0",
    sessionName: String = "session",
    windowIndex: String = "0",
    windowID: String = "@0",
    paneIndex: String = "0",
    panePID: String = "123",
    paneActive: String = "1",
    currentCommand: String = "zsh",
    paneDead: String = "0",
    deadStatus: String = "",
    deadSignal: String = "",
    tty: String = "/dev/ttys000",
    currentPath: String = "/tmp",
    title: String = "title"
  ) -> String {
    [
      paneID, sessionName, windowIndex, windowID, paneIndex, panePID, paneActive,
      currentCommand, paneDead, deadStatus, deadSignal, tty, currentPath, title,
    ].joined(separator: "\\037")
  }

  private func fixture(named name: String) throws -> String {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    )
    return try String(contentsOf: fixtureURL, encoding: .utf8)
  }
}

private let isTmuxListPanesIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "tmux session 名の往復統合",
  .enabled(if: isTmuxListPanesIntegrationEnabled)
)
struct TmuxListPanesIntegrationTests {

  @Test("$ とバックスラッシュを含む session 名を parse 後の target で指定する")
  func roundTripsSessionNameThroughHasSession() async throws {
    let processID = ProcessInfo.processInfo.processIdentifier
    let socketName = "awt-list-panes-round-trip-\(processID)"
    let socketURL = integrationSocketURL(socketName: socketName)
    let sessionName = "awt-$\(processID)\\session"
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
      try #require((serverPID ?? 0) > 0)

      let output = try await runner.run(arguments: ["list-panes", "-a", "-F", TmuxListPanes.format])
      let result = TmuxListPanes.parse(output: output.stdout)
      let parsedName = try #require(result.panes.first?.sessionName)

      #expect(result.failures.isEmpty)
      let roundTrip = try await runner.run(arguments: ["has-session", "-t", parsedName])
      #expect(roundTrip.exitCode == 0)
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
      // 生きている server の socket を消すと `-L` から到達不能になるため、停止未確認なら残す。
      FileHandle.standardError.write(
        Data("警告: tmux server を停止できなかったため socket を残します: \(socketURL.path)\n".utf8)
      )
      return
    }
    try? FileManager.default.removeItem(at: socketURL)
  }

  private func terminateServer(_ serverPID: pid_t) -> Bool {
    // 0 以下は kill(2) でプロセスグループ等を指すため、外部出力を syscall へ渡す前に弾く。
    guard serverPID > 0 else { return false }
    guard Darwin.kill(serverPID, SIGTERM) == 0 else { return errno == ESRCH }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(500))
    while clock.now < deadline {
      guard Darwin.kill(serverPID, 0) == 0 else { return errno == ESRCH }
      Darwin.usleep(10_000)
    }
    return Darwin.kill(serverPID, 0) != 0 && errno == ESRCH
  }
}
