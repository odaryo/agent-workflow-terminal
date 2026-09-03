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
        exitCode: 0, stdout: #"%7\037title\0371\03712345"# + "\n", stderr: ""
      ),
      ProcessRunResult(exitCode: 0, stdout: "screen\n", stderr: ""),
    ])
    let source = try makeSource(tmux: tmux, process: QueueProcessSpy(results: []))
    let signals = try await source.signals(for: pane(id: "%7", pid: 70))

    #expect(signals.paneTitle == "title")
    #expect(signals.screenText == "screen\n")
    #expect(signals.isPaneInMode)
    #expect(signals.secondsSinceOutput == nil)
    let calls = await tmux.calls
    #expect(calls.count == 2)
    #expect(
      calls[0].suffix(5)
        == [
          "display-message", "-p", "-t", "%7", TmuxListPanes.agentPaneStatusFormat,
        ]
    )
    #expect(calls[1].suffix(4) == ["capture-pane", "-p", "-t", "%7"])
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
      try await source.signals(for: pane(id: "session", pid: 70))
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
