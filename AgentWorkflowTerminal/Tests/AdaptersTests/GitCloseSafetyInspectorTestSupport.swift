import Foundation
import TerminalCore
import Testing

@testable import Adapters

extension GitCloseSafetyInspectorTests {
  @Test("既定 branch 不明と merge-base の異常を unknown のまま返す")
  func keepsUnknownAndMergeErrors() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +1 -0\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +1 -0\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let noDefault = GitCloseSafetyInspector(
      runner: try runner(results), target: try target(branch: "topic"))
    let unknown = await noDefault.inspect(projectRootBranch: nil)
    #expect(unknown.report.inspection.branchMerge == .unknown)
    #expect(unknown.report.defaultBranch == .unresolved(reason: .originHeadMissing))
    #expect(unknown.failures.isEmpty)

    let mergeFailure = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +1 -0\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +1 -0\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
      .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: "")),
      .success(.init(exitCode: 128, stdout: "", stderr: "fatal: bad revision\n")),
    ])
    let failedMerge = await GitCloseSafetyInspector(
      runner: try runner(mergeFailure), target: try target(branch: "topic")
    ).inspect(projectRootBranch: nil)
    #expect(failedMerge.report.inspection.branchMerge == .unknown)
    #expect(failedMerge.failures.map(\.check) == [.branchMerge])
  }

  func runner(_ processRunner: any ProcessRunning) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: processRunner,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
      isExecutableFile: { _ in true })
  }

  func target(
    identity: String = "/repo/.git/worktrees/topic", branch: String?
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: identity)), worktreePath: "/repo/wt",
      branch: branch, isProjectRoot: false)
  }

}

func commandArguments(_ arguments: [String]) -> [String] {
  Array(arguments.dropFirst(4))
}

actor CloseInspectionProcessStub: ProcessRunning {
  private let handler: @Sendable ([String]) -> Result<ProcessRunResult, ProcessRunnerError>

  init(handler: @escaping @Sendable ([String]) -> Result<ProcessRunResult, ProcessRunnerError>) {
    self.handler = handler
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    try handler(arguments).get()
  }
}

actor CloseInspectionResultQueue: ProcessRunning {
  private var results: [Result<ProcessRunResult, ProcessRunnerError>]

  init(_ results: [Result<ProcessRunResult, ProcessRunnerError>]) {
    self.results = results
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    try results.removeFirst().get()
  }
}
