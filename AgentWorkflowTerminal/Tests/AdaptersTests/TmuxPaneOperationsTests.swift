import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("設計書 §4.1 の tmux 操作が渡す引数")
struct TmuxPaneOperationsTests {
  private let executableURL = URL(fileURLWithPath: "/test/bin/tmux")
  private let prefix = ["-u", "-L", "awt-test"]
  private let pane = PaneID(rawValue: "%3")

  @Test("左右に並べる分割は -h を使い、生成された pane の ID を返す")
  func splitsLeftRight() async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "%7\n", stderr: "")))
    let operations = try makeOperations(stub)

    let created = try await operations.splitLeftRight(pane: pane)

    #expect(created == PaneID(rawValue: "%7"))
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["split-window", "-t", "%3", "-h", "-P", "-F", "#{pane_id}"])
  }

  @Test("上下に並べる分割は -v を使い、生成された pane の ID を返す")
  func splitsTopBottom() async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "%7\n", stderr: "")))
    let operations = try makeOperations(stub)

    let created = try await operations.splitTopBottom(pane: pane)

    #expect(created == PaneID(rawValue: "%7"))
    #expect(
      await stub.invocations.first?.arguments
        == prefix + ["split-window", "-t", "%3", "-v", "-P", "-F", "#{pane_id}"])
  }

  @Test("pane ID として読めない分割出力を捨てずにエラーへ載せる", arguments: ["", "\n", "pane\n", "%\n"])
  func rejectsUnexpectedSplitOutput(_ stdout: String) async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: stdout, stderr: "")))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxPaneOperationError.unexpectedSplitOutput(stdout)) {
      try await operations.splitLeftRight(pane: pane)
    }
  }

  @Test("pane を閉じる")
  func closesPane() async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.close(pane: pane)

    #expect(await stub.invocations.first?.arguments == prefix + ["kill-pane", "-t", "%3"])
  }

  @Test("pane を選択する")
  func selectsPane() async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.select(pane: pane)

    #expect(await stub.invocations.first?.arguments == prefix + ["select-pane", "-t", "%3"])
  }

  @Test(
    "方向で pane を移動する",
    arguments: zip(
      [TmuxPaneDirection.left, .right, .up, .down],
      ["-L", "-R", "-U", "-D"]
    )
  )
  func selectsNeighbor(_ direction: TmuxPaneDirection, _ flag: String) async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.selectNeighbor(of: pane, direction: direction)

    #expect(
      await stub.invocations.first?.arguments == prefix + ["select-pane", "-t", "%3", flag])
  }

  @Test("zoom した状態にする指示は、既に zoom 済みなら存在確認だけをする条件付き実行になる")
  func setsZoomOn() async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.setZoom(true, pane: pane)

    #expect(
      await stub.invocations.first?.arguments
        == prefix + [
          "if-shell", "-F", "-t", "%3",
          "#{&&:#{pane_active},#{window_zoomed_flag}}",
          "list-panes -t %3 -f 0",
          "select-pane -t %3 ; resize-pane -t %3 -Z",
        ])
  }

  @Test("zoom を解除した状態にする指示は、zoom 中のときだけ toggle する")
  func setsZoomOff() async throws {
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let operations = try makeOperations(stub)

    try await operations.setZoom(false, pane: pane)

    #expect(
      await stub.invocations.first?.arguments
        == prefix + [
          "if-shell", "-F", "-t", "%3",
          "#{&&:#{pane_active},#{window_zoomed_flag}}",
          "resize-pane -t %3 -Z",
          "list-panes -t %3 -f 0",
        ])
  }

  @Test("tmux 3.4 が返す can't find pane を対象 pane つきのエラーにする")
  func mapsMissingPaneToPaneNotFound() async throws {
    let stub = ProcessRunnerStub(
      result: .success(.init(exitCode: 1, stdout: "", stderr: "can't find pane: %3\n")))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxPaneOperationError.paneNotFound(pane)) {
      try await operations.close(pane: pane)
    }
  }

  @Test("別 pane を指す can't find pane は対象 pane の不在に丸めない")
  func keepsMismatchedMissingPaneAsRawFailure() async throws {
    let stderr = "can't find pane: %9\n"
    let stub = ProcessRunnerStub(
      result: .success(.init(exitCode: 1, stdout: "", stderr: stderr)))
    let operations = try makeOperations(stub)

    await #expect(
      throws: TmuxPaneOperationError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: stderr))
    ) {
      try await operations.close(pane: pane)
    }
  }

  @Test("空き領域が無い分割の失敗を終了コードと stderr のまま返す")
  func keepsNoSpaceFailureAsRawFailure() async throws {
    let stderr = "no space for new pane\n"
    let stub = ProcessRunnerStub(
      result: .success(.init(exitCode: 1, stdout: "", stderr: stderr)))
    let operations = try makeOperations(stub)

    await #expect(
      throws: TmuxPaneOperationError.tmux(
        .commandFailed(exitCode: 1, stdout: "", stderr: stderr))
    ) {
      try await operations.splitTopBottom(pane: pane)
    }
  }

  @Test(
    "`%N` 以外の pane ID を tmux へ渡す前に拒否する",
    arguments: ["", "%", "3", "%x", "%-1", "%+1", "% 1", "%0 ; kill-server", "@0", "-h"]
  )
  func rejectsMalformedPaneIDBeforeRunningTmux(_ rawValue: String) async throws {
    let malformed = PaneID(rawValue: rawValue)
    let stub = ProcessRunnerStub(result: .success(.init(exitCode: 0, stdout: "%7\n", stderr: "")))
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxPaneOperationError.invalidPaneID(malformed)) {
      try await operations.setZoom(true, pane: malformed)
    }
    await #expect(throws: TmuxPaneOperationError.invalidPaneID(malformed)) {
      try await operations.splitLeftRight(pane: malformed)
    }
    await #expect(throws: TmuxPaneOperationError.invalidPaneID(malformed)) {
      try await operations.close(pane: malformed)
    }
    await #expect(throws: TmuxPaneOperationError.invalidPaneID(malformed)) {
      try await operations.select(pane: malformed)
    }
    await #expect(throws: TmuxPaneOperationError.invalidPaneID(malformed)) {
      try await operations.selectNeighbor(of: malformed, direction: .left)
    }
    #expect(await stub.invocations.isEmpty)
  }

  private func makeOperations(_ stub: ProcessRunnerStub) throws -> TmuxPaneOperations {
    TmuxPaneOperations(
      runner: try TmuxRunner(
        socketName: "awt-test",
        processRunner: stub,
        executableCandidates: [executableURL],
        parentEnvironment: [:],
        isExecutableFile: { _ in true }
      ))
  }
}

private struct StubInvocation: Sendable, Equatable {
  let arguments: [String]
}

private actor ProcessRunnerStub: ProcessRunning {
  private let result: Result<ProcessRunResult, ProcessRunnerError>
  private(set) var invocations: [StubInvocation] = []

  init(result: Result<ProcessRunResult, ProcessRunnerError>) {
    self.result = result
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(StubInvocation(arguments: arguments))
    return try result.get()
  }
}
