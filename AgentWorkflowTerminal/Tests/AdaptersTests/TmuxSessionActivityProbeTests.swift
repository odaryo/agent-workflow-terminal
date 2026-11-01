import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("session 活動 probe の失敗と鮮度 (設計書 §3.1)")
struct TmuxSessionActivityProbeTests {
  @Test("list-panes または ps の失敗は undetermined", arguments: ActivityProbeFailure.allCases)
  func failuresAreUndetermined(failure: ActivityProbeFailure) async throws {
    let key = try makeKey()
    let spy = ActivityProbeProcessSpy(key: key, failure: failure)
    let probe = try makeProbe(spy: spy)

    #expect(await probe.activity(of: key) == .undetermined)
  }

  @Test("連続した呼び出しでも ps を取り直し、出現した子を running と判定する")
  func refreshesProcessTableOnEveryCall() async throws {
    let key = try makeKey()
    let spy = ActivityProbeProcessSpy(key: key)
    let probe = try makeProbe(spy: spy)

    #expect(await probe.activity(of: key) == .shellOnly)
    #expect(await probe.activity(of: key) == .running)
    #expect(await spy.processReads == 2)
  }

  @Test(
    "死んだ pane の空 PID は除外し、生存 pane の空 PID は undetermined",
    arguments: [
      (" 1\n", TerminalSessionActivity.shellOnly),
      (" 1\n100 0\n", .shellOnly),
      (" 1\n 0\n", .undetermined),
      ("200 1\n100 0\n", .shellOnly),
    ])
  func handlesDeadPanePID(paneOutput: String, expected: TerminalSessionActivity) async throws {
    let key = try makeKey()
    let spy = ActivityProbeProcessSpy(
      key: key, paneOutput: paneOutput, processTableOutput: "100 1 zsh\n")
    let probe = try makeProbe(spy: spy)

    #expect(await probe.activity(of: key) == expected)
  }

  private func makeKey() throws -> TerminalSessionKey {
    .primary(try #require(WorktreeIdentity(rawValue: "/repo/.git")))
  }

  private func makeProbe(spy: ActivityProbeProcessSpy) throws -> TmuxSessionActivityProbe {
    TmuxSessionActivityProbe(
      tmuxRunner: try makeTmuxRunner(socketName: "activity-test", processRunner: spy),
      processRunner: spy, processExecutableURL: URL(fileURLWithPath: "/activity-ps"))
  }
}

enum ActivityProbeFailure: Sendable, CaseIterable {
  case paneListNonzero
  case paneListLaunch
  case sessionMissing
  case processTableNonzero
  case processTableLaunch
}

private actor ActivityProbeProcessSpy: ProcessRunning {
  private let key: TerminalSessionKey
  private let failure: ActivityProbeFailure?
  private let paneOutput: String?
  private let processTableOutput: String?
  private(set) var processReads = 0

  init(
    key: TerminalSessionKey, failure: ActivityProbeFailure? = nil,
    paneOutput: String? = nil, processTableOutput: String? = nil
  ) {
    self.key = key
    self.failure = failure
    self.paneOutput = paneOutput
    self.processTableOutput = processTableOutput
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    if executableURL.path == "/activity-ps" {
      processReads += 1
      if failure == .processTableLaunch {
        throw .launchFailed(executableURL: executableURL, message: "ps unavailable")
      }
      if failure == .processTableNonzero {
        return ProcessRunResult(exitCode: 1, stdout: "", stderr: "ps failed")
      }
      #expect(arguments == ["-Ao", "pid=,ppid=,ucomm="])
      #expect(environment["LC_ALL"] == "C")
      let child = processReads > 1 ? "101 100 sleep\n" : ""
      return ProcessRunResult(
        exitCode: 0, stdout: processTableOutput ?? ("100 1 sh\n" + child), stderr: "")
    }
    if failure == .paneListLaunch {
      throw .launchFailed(executableURL: executableURL, message: "tmux unavailable")
    }
    if failure == .paneListNonzero || failure == .sessionMissing {
      return ProcessRunResult(
        exitCode: 1, stdout: "",
        stderr: failure == .sessionMissing
          ? "can't find session: \(TmuxSessionName(key: key).rawValue)\n" : "list-panes failed")
    }
    #expect(arguments.contains("list-panes"))
    #expect(arguments.contains("-s"))
    if let targetIndex = arguments.firstIndex(of: "-t"),
      arguments.indices.contains(targetIndex + 1)
    {
      #expect(arguments[targetIndex + 1] == "=\(TmuxSessionName(key: key).rawValue):")
    } else {
      Issue.record("list-panes に session の target が無い")
    }
    if let paneOutput {
      return ProcessRunResult(exitCode: 0, stdout: paneOutput, stderr: "")
    }
    guard let formatIndex = arguments.firstIndex(of: "-F"),
      arguments.indices.contains(formatIndex + 1)
    else {
      Issue.record("list-panes に明示的な format が無い")
      return ProcessRunResult(exitCode: 1, stdout: "", stderr: "missing format")
    }
    let tokens = [
      "pane_id": "%1", "session_name": TmuxSessionName(key: key).rawValue,
      "window_index": "0", "window_id": "@0", "pane_index": "0", "pane_pid": "100",
      "pane_active": "1", "pane_current_command": "sh", "pane_dead": "0",
      "pane_dead_status": "", "pane_dead_signal": "", "pane_tty": "/dev/ttys000",
      "pane_current_path": "/tmp", "pane_title": "",
    ]
    var line = arguments[formatIndex + 1]
    for (token, value) in tokens {
      line = line.replacingOccurrences(of: "#{\(token)}", with: value)
      line = line.replacingOccurrences(of: #"#{s/\\/\\\\/:"# + token + "}", with: value)
    }
    return ProcessRunResult(exitCode: 0, stdout: line + "\n", stderr: "")
  }
}
