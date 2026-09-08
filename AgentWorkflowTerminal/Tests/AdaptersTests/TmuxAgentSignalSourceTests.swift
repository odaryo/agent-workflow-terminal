import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("tmux Agent signals と ps 生存確認")
struct TmuxAgentSignalSourceTests {
  @Test("display-message と capture-pane の2回で対象 pane の信号を取る")
  func signalsArguments() async throws {
    let tmux = QueueProcessSpy(results: [
      ProcessRunResult(
        exitCode: 0, stdout: #"%7\037title"# + "\n", stderr: ""
      ),
      ProcessRunResult(exitCode: 0, stdout: "screen\n", stderr: ""),
    ])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))
    let signals = try await source.signals(for: pane(id: "%7", pid: 70), minimumChangedLines: 1)

    #expect(signals.paneTitle == "title")
    #expect(signals.screenText == "screen\n")
    #expect(signals.secondsSinceScreenChange == nil)
    let calls = await tmux.calls
    #expect(calls.count == 2)
    #expect(
      calls[0].suffix(5)
        == [
          "display-message", "-p", "-t", "%7", TmuxListPanes.agentPaneStatusFormat,
        ]
    )
    #expect(calls[1].suffix(5) == ["capture-pane", "-e", "-p", "-t", "%7"])
  }

  @Test("画面差分から pane 単位の最終変化時刻を追跡する")
  func tracksScreenChanges() async throws {
    let status = ProcessRunResult(
      exitCode: 0, stdout: #"%7\037title"# + "\n", stderr: ""
    )
    let tmux = QueueProcessSpy(results: [
      status,
      ProcessRunResult(exitCode: 0, stdout: "first", stderr: ""),
      status,
      ProcessRunResult(exitCode: 0, stdout: "first", stderr: ""),
      status,
      ProcessRunResult(exitCode: 0, stdout: "second", stderr: ""),
    ])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))

    let first = try await source.signals(for: pane(id: "%7", pid: 70), minimumChangedLines: 1)
    let unchanged = try await source.signals(for: pane(id: "%7", pid: 70), minimumChangedLines: 1)
    let changed = try await source.signals(for: pane(id: "%7", pid: 70), minimumChangedLines: 1)

    #expect(first.secondsSinceScreenChange == nil)
    #expect(unchanged.secondsSinceScreenChange.map { $0 >= 0 } == true)
    #expect(changed.secondsSinceScreenChange == 0)
  }

  @Test("しきい値 2 では1行だけ違う画面が続いても鮮度を 0 に戻さない")
  func honorsMinimumChangedLines() async throws {
    let status = ProcessRunResult(
      exitCode: 0, stdout: #"%7\037title"# + "\n", stderr: ""
    )
    // idle 真値区間で実際に観測されたステータス行の遷移 (Spikes/gate3/README.md §13.0) と、
    // 2 行が動く出力。
    let statusLines = [
      "● high · /effort",
      "tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf and reattach"
        + " for focus tracking",
      "",
    ]
    let tmux = QueueProcessSpy(
      results: statusLines.flatMap {
        [status, ProcessRunResult(exitCode: 0, stdout: "❯ \n\($0)", stderr: "")]
      } + [status, ProcessRunResult(exitCode: 0, stdout: "⏺ writing\n· done 3 lines", stderr: "")])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))
    let pane = pane(id: "%7", pid: 70)

    let first = try await source.signals(for: pane, minimumChangedLines: 2)
    let hintOnly = try await source.signals(for: pane, minimumChangedLines: 2)
    let stillHintOnly = try await source.signals(for: pane, minimumChangedLines: 2)
    let output = try await source.signals(for: pane, minimumChangedLines: 2)

    #expect(first.secondsSinceScreenChange == nil)
    #expect(hintOnly.secondsSinceScreenChange.map { $0 > 0 } == true)
    let elapsed = try #require(stillHintOnly.secondsSinceScreenChange)
    #expect(elapsed >= (hintOnly.secondsSinceScreenChange ?? 0))
    #expect(output.secondsSinceScreenChange == 0)
  }

  @Test("生産した画面変化信号がそのまま Claude の Working 判定へ届く")
  func connectsSignalProducerToClassifier() async throws {
    let status = ProcessRunResult(
      exitCode: 0, stdout: #"%7\037title"# + "\n", stderr: ""
    )
    let tmux = QueueProcessSpy(results: [
      status,
      ProcessRunResult(exitCode: 0, stdout: "first frame", stderr: ""),
      status,
      ProcessRunResult(exitCode: 0, stdout: "second frame", stderr: ""),
    ])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))
    let pane = pane(id: "%7", pid: 70)

    let initial = try await source.signals(for: pane, minimumChangedLines: 1)
    let changed = try await source.signals(for: pane, minimumChangedLines: 1)

    #expect(
      fixtureState(ClaudeCodeAdapter().classify(signals: initial, liveness: .alive)) == "unknown")
    #expect(
      fixtureState(ClaudeCodeAdapter().classify(signals: changed, liveness: .alive)) == "working")
  }

  @Test("absent を観測した pane の画面履歴を解放する")
  func absentForgetsScreen() async throws {
    let status = ProcessRunResult(
      exitCode: 0, stdout: #"%7\037title"# + "\n", stderr: ""
    )
    let tmux = QueueProcessSpy(results: [
      status,
      ProcessRunResult(exitCode: 0, stdout: "screen", stderr: ""),
      status,
      ProcessRunResult(exitCode: 0, stdout: "screen", stderr: ""),
    ])
    let process = QueueProcessSpy(results: [
      ProcessRunResult(exitCode: 0, stdout: "70 1 /bin/sh\n", stderr: "")
    ])
    let source = try makeSource(tmux: tmux, process: process)
    let pane = pane(id: "%7", pid: 70)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)

    #expect(await source.liveness(for: pane, matchingProcessNames: ["agent"]) == .absent)
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
  }

  @Test("capture 失敗を画面利用不能の信号として Adapter へ渡す")
  func captureFailureIsScreenUnavailable() async throws {
    let tmux = QueueProcessSpy(results: [
      ProcessRunResult(exitCode: 0, stdout: #"%7\037title"# + "\n", stderr: ""),
      ProcessRunResult(exitCode: 1, stdout: "", stderr: "can't find pane"),
    ])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))
    let signals = try await source.signals(for: pane(id: "%7", pid: 70), minimumChangedLines: 1)

    guard
      case .observation(let observation) = ClaudeCodeAdapter().classify(
        signals: signals, liveness: .alive
      )
    else {
      Issue.record("状態観測が必要")
      return
    }
    #expect(observation.unknownReason == .screenUnavailable)
  }

  @Test("消えた pane の空フィールドを parse 失敗と区別する")
  func missingPane() async throws {
    let status = ProcessRunResult(
      exitCode: 0, stdout: #"%7\037title"# + "\n", stderr: ""
    )
    let tmux = QueueProcessSpy(results: [
      status,
      ProcessRunResult(exitCode: 0, stdout: "screen", stderr: ""),
      ProcessRunResult(exitCode: 0, stdout: #"\037"# + "\n", stderr: ""),
      status,
      ProcessRunResult(exitCode: 0, stdout: "screen", stderr: ""),
    ])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))
    let pane = pane(id: "%7", pid: 70)
    _ = try await source.signals(for: pane, minimumChangedLines: 1)

    await #expect(throws: TmuxAgentSignalSourceError.paneNotFound(PaneID(rawValue: "%7"))) {
      try await source.signals(for: pane, minimumChangedLines: 1)
    }
    #expect(
      try await source.signals(for: pane, minimumChangedLines: 1).secondsSinceScreenChange == nil)
  }

  @Test("pane_pid 自身が一致すれば子がいなくても alive")
  func rootProcessIsAlive() async throws {
    let process = QueueProcessSpy(results: [
      ProcessRunResult(exitCode: 0, stdout: "70 1 /opt/tools/agent\n", stderr: "")
    ])
    let source = try makeSource(tmux: QueueProcessSpy(results: []), process: process)
    #expect(
      await source.liveness(
        for: pane(id: "%7", pid: 70), matchingProcessNames: ["agent"]
      ) == .alive
    )
  }

  @Test("フルパスと空白を保った comm を process 名として照合する")
  func parsesFullPathWithSpaces() async throws {
    let process = QueueProcessSpy(results: [
      ProcessRunResult(
        exitCode: 0,
        stdout: "70 1 /bin/sh\n71 70 /Applications/Agent Tool\n",
        stderr: ""
      )
    ])
    let source = try makeSource(tmux: QueueProcessSpy(results: []), process: process)
    #expect(
      await source.liveness(
        for: pane(id: "%7", pid: 70), matchingProcessNames: ["Agent Tool"]
      ) == .alive
    )
  }

  @Test("不正な pane ID は tmux に渡さない")
  func rejectsInvalidPaneID() async throws {
    let tmux = QueueProcessSpy(results: [])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))
    await #expect(throws: TmuxAgentSignalSourceError.self) {
      try await source.signals(for: pane(id: "session", pid: 70), minimumChangedLines: 1)
    }
    #expect(await tmux.calls.isEmpty)
  }

  private func makeSource(
    tmux: QueueProcessSpy, process: QueueProcessSpy
  ) throws -> TmuxAgentSignalSource {
    let runner = try TmuxRunner(
      socketName: "signals-test", processRunner: tmux,
      executableCandidates: [URL(fileURLWithPath: "/tmux")],
      parentEnvironment: [:], isExecutableFile: { _ in true }
    )
    return TmuxAgentSignalSource(
      tmuxRunner: runner, processRunner: process,
      processExecutableURL: URL(fileURLWithPath: "/ps")
    )
  }

  private func pane(id: String, pid: Int32) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: id), processID: pid, tty: "", currentCommand: "",
      currentPath: "", title: "", termination: nil
    )
  }
}

private func fixtureState(_ result: AgentObservationResult) -> String {
  switch result {
  case .absent: "absent"
  case .observation(let observation): observation.state.rawValue
  }
}

private actor QueueProcessSpy: ProcessRunning {
  private var results: [ProcessRunResult]
  private(set) var calls: [[String]] = []
  init(results: [ProcessRunResult]) { self.results = results }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(arguments)
    guard !results.isEmpty else { throw .cancelled }
    return results.removeFirst()
  }
}
