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
    // `tmux -u -L awt-issue12-fixtures-28020 new-session -d -s path-fixture -c <上記path>
    //   "printf '\033]2;題名🚀\007'; exec sleep 120"`
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

  @Test("$ の次の文字に応じて session 名の追加 escape だけを除く")
  func decodesConditionalDollarEscapesInSessionNames() throws {
    // 採取: tmux 3.4 / socket `awt-issue12-r2-sessions-20260902`。
    // `for name in 'letter$a' 'under$_' 'brace${x}' 'digit\$1' 'double$$'
    //   'terminal$' 'symbol$-'; do tmux -u -L awt-issue12-r2-sessions-20260902
    //   new-session -d -s "$name" 'sleep 120'; done`
    // `tmux -u -L awt-issue12-r2-sessions-20260902 list-panes -a -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-dollar-pattern-sessions.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(
      result.panes.map(\.sessionName)
        == [
          #"brace\${x}"#,
          #"digit\\$1"#,
          "double$$",
          #"letter\$a"#,
          "symbol$-",
          "terminal$",
          #"under\$_"#,
        ]
    )
  }

  @Test("$ の次の文字に応じて path の追加 escape だけを除く")
  func decodesConditionalDollarEscapesInRawFields() throws {
    // 採取: tmux 3.4 / socket `awt-issue12-r2-paths-20260902`。
    // `for path in 'letter$a' 'under$_' 'brace${x}' 'digit$1' 'double$$'
    //   'terminal$' 'symbol$-'; do mkdir -p "$root/$path"; tmux -u -L
    //   awt-issue12-r2-paths-20260902 new-session -d -s "path-$index" -c "$root/$path"
    //   'sleep 120'; done`
    // `tmux -u -L awt-issue12-r2-paths-20260902 list-panes -a -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-dollar-pattern-paths.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(
      result.panes.map { URL(fileURLWithPath: $0.currentPath).lastPathComponent }
        == ["letter$a", "under$_", "brace${x}", "digit$1", "double$$", "terminal$", "symbol$-"]
    )
  }

  @Test("tmux の named escape と八進 escape を1パスで真の制御バイトへ戻す")
  func decodesControlBytesInRawField() throws {
    // `name=$(printf 'p\001\002\003\004\005\006\007\010\011\013\014\015')`
    // `name+=$(printf '\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\177q')`
    // `mkdir "/private/tmp/awt-issue12-r2-fixtures-oGQpJI/control/$name"`
    // `tmux -u -L awt-issue12-r2-fixtures-87037 new-session -d -s control-path
    //   -c <上記path> 'sleep 120'; tmux -u -L awt-issue12-r2-fixtures-87037 list-panes
    //   -t control-path -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-control-path.txt")
    )
    let pane = try #require(result.panes.first)
    let controlBytes = Array(UInt8(1)...UInt8(9)) + Array(UInt8(11)...UInt8(30)) + [127]
    let expectedSuffix = "p" + String(decoding: controlBytes, as: UTF8.self) + "q"

    #expect(result.failures.isEmpty)
    #expect(pane.currentPath.hasSuffix(expectedSuffix))
  }

  @Test("リテラル escape 文字列を制御バイトへ二重復号しない")
  func preservesLiteralEscapeSequencesInRawField() throws {
    let pane = try TmuxListPanes.parse(
      line: encodedLine(currentCommand: #"literal\\001\\a\\037"#)
    )

    #expect(pane.currentCommand == #"literal\001\a\037"#)
  }

  @Test("実 0x1F を含む pane は区切り衝突を parse failure にする")
  func rejectsUnitSeparatorCollisionFixture() throws {
    // 採取: tmux 3.4 / socket `awt-issue12-r2-fixtures2-87612`。
    // `mkdir "$root/collision/$(printf 'p\037q')"; tmux -u -L
    //   awt-issue12-r2-fixtures2-87612 new-session -d -s collision-path -c <上記path>
    //   'sleep 120'; tmux -u -L awt-issue12-r2-fixtures2-87612
    //   list-panes -t collision-path -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-unit-separator-path.txt")
    )

    #expect(result.panes.isEmpty)
    #expect(result.failures.map(\.error) == [.invalidFieldCount(actual: 15)])
  }

  @Test("hostile な session 名を新 format の実出力から保持する")
  func parsesHostileSessionFixture() throws {
    // 採取: `tmux -u -L awt-issue12-r2-fixtures-87037 new-session -d
    //   -s 'host\$1\\name \037 literal\ttab\nline' 'sleep 120'`
    // `tmux -u -L awt-issue12-r2-fixtures-87037 list-panes -t %10 -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.4-list-panes-hostile-session-r2.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(result.panes.first?.sessionName == #"host\\$1\\name \\037 literal\ttab\nline"#)
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
    #expect(pane.snapshot.termination == .exited(status: 23))
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
    #expect(result.panes.first?.snapshot.termination == .signaled("term"))
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

  @Test("条件を満たす $ の直前だけから tmux の挿入分を除く")
  func decodesInsertedDollarEscapeWithoutDamagingBackslashes() throws {
    let pane = try TmuxListPanes.parse(
      line: encodedLine(currentCommand: #"\\\$a"#)
    )

    #expect(pane.currentCommand == #"\$a"#)
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

  @Test("生 TAB と LF を含む command は line 単位なら保持し output では failure にする")
  func handlesTabAndLineFeedInRawFieldFixture() throws {
    // 採取: tmux 3.4 / socket `awt-issue12-r2-fixtures-87037`。
    // `command=$(printf 'cmd\\sl\nash\tz'); printf '#include <unistd.h>\nint main(void)
    //   {sleep(120);return 0;}\n' | cc -x c -o "$root/$command" -`
    // `tmux -u -L awt-issue12-r2-fixtures-87037 new-session -d -s command-lf "$root/$command"`
    // `tmux -u -L awt-issue12-r2-fixtures-87037 list-panes -t command-lf -F "$format"`
    let output = try fixture(named: "tmux-3.4-list-panes-raw-current-command-r2.txt")
    let pane = try TmuxListPanes.parse(line: String(output.dropLast()))
    let result = TmuxListPanes.parse(output: output)

    #expect(pane.currentCommand == "cmd\\sl\nash\tz")
    #expect(result.panes.isEmpty)
    #expect(!result.failures.isEmpty)
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
          termination: nil
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

  @Test("dead pane の終了理由がまだ観測できなくても pane を保持する")
  func preservesUnknownDeadTermination() throws {
    let pane = try TmuxListPanes.parse(line: encodedLine(paneDead: "1"))

    #expect(pane.termination == .unknown)
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

  @Test("pane ID と window ID の負数を拒否する")
  func rejectsNegativeObjectIDs() {
    #expect(throws: TmuxListPanesParseError.invalidPaneID("%-1")) {
      try TmuxListPanes.parse(line: encodedLine(paneID: "%-1"))
    }
    #expect(throws: TmuxListPanesParseError.invalidWindowID("@-1")) {
      try TmuxListPanes.parse(line: encodedLine(windowID: "@-1"))
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

  @Test("$ の全分岐を parse 後の session target で指定する")
  func roundTripsConditionalDollarEscapesThroughHasSession() async throws {
    let processID = ProcessInfo.processInfo.processIdentifier
    let socketName = "awt-list-panes-round-trip-\(processID)"
    let socketURL = integrationSocketURL(socketName: socketName)
    let prefix = "awt-\(processID)-"
    let sessionNames = [
      prefix + "letter$a",
      prefix + "under$_",
      prefix + "brace${x}",
      prefix + "digit\\$1",
      prefix + "double$$",
      prefix + "terminal$",
      prefix + "symbol$-",
    ]
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
        arguments: ["new-session", "-d", "-s", sessionNames[0], "-P", "-F", "#{pid}"])
      serverPID = pid_t(server.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      try #require((serverPID ?? 0) > 0)
      for sessionName in sessionNames.dropFirst() {
        _ = try await runner.run(
          arguments: ["new-session", "-d", "-s", sessionName, "sleep 120"])
      }

      let output = try await runner.run(arguments: ["list-panes", "-a", "-F", TmuxListPanes.format])
      let result = TmuxListPanes.parse(output: output.stdout)

      #expect(result.failures.isEmpty)
      #expect(result.panes.count == sessionNames.count)
      for parsedName in result.panes.map(\.sessionName) {
        _ = try await runner.run(arguments: ["has-session", "-t", parsedName])
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
