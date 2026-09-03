import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("capture-pane の引数と出力")
struct TmuxCapturePaneTests {
  @Test("pane ID を target にして画面を加工せず返す")
  func capturesScreen() async throws {
    let spy = CaptureProcessSpy(
      result: ProcessRunResult(exitCode: 0, stdout: "line\n\n", stderr: ""))
    let runner = try TmuxRunner(
      socketName: "capture-test", processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/tmux")],
      parentEnvironment: [:], isExecutableFile: { _ in true }
    )
    let output = try await TmuxCapturePane(runner: runner).capture(PaneID(rawValue: "%7"))
    #expect(output == "line\n\n")
    let call = try #require(await spy.calls.first)
    #expect(call.arguments == ["-u", "-L", "capture-test", "capture-pane", "-p", "-t", "%7"])
  }

  @Test("不正な pane ID は tmux へ渡さない")
  func rejectsInvalidPaneID() async throws {
    let spy = CaptureProcessSpy(
      result: ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
    )
    let runner = try TmuxRunner(
      socketName: "capture-test", processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/tmux")],
      parentEnvironment: [:], isExecutableFile: { _ in true }
    )
    await #expect(throws: TmuxCapturePaneError.invalidPaneID(PaneID(rawValue: "other"))) {
      try await TmuxCapturePane(runner: runner).capture(PaneID(rawValue: "other"))
    }
    #expect(await spy.calls.isEmpty)
  }
}

private actor CaptureProcessSpy: ProcessRunning {
  struct Call: Sendable { let arguments: [String] }
  private(set) var calls: [Call] = []
  let result: ProcessRunResult
  init(result: ProcessRunResult) { self.result = result }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(Call(arguments: arguments))
    return result
  }
}
