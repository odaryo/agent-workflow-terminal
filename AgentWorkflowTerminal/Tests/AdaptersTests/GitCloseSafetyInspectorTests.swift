import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("Close 前の git 安全確認 (設計書 §3.4)")
struct GitCloseSafetyInspectorTests {
  @Test("untracked と upstream 不在を警告し、origin/HEAD へのマージを判定する")
  func inspectsWarningsAndOriginDefaultBranch() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments:
        .success(
          .init(
            exitCode: 0,
            stdout: "# branch.oid abc\0# branch.head topic\0? new.txt\0",
            stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["merge-base", "--is-ancestor", "topic", "refs/remotes/origin/main"]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: "topic")

    let result = await inspector.inspect(detectedWorktrees: [])

    #expect(result.inspection.uncommittedChanges == .present)
    #expect(result.inspection.unpushedCommits == .present)
    #expect(result.inspection.branchMerge == .merged)
    #expect(result.defaultBranch == "main")
    #expect(result.failures.isEmpty)
  }

  @Test("origin/HEAD 不在なら Project Root の branch へフォールバックする")
  func fallsBackToProjectRootBranch() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments:
        .success(
          .init(
            exitCode: 0,
            stdout:
              "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -2\0",
            stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["merge-base", "--is-ancestor", "topic", "main"]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: "topic")

    let result = await inspector.inspect(detectedWorktrees: [try detectedRoot(branch: "main")])

    #expect(result.inspection.uncommittedChanges == .absent)
    #expect(result.inspection.unpushedCommits == .absent)
    #expect(result.inspection.branchMerge == .unmerged)
    #expect(result.defaultBranch == "main")
    #expect(result.failures.isEmpty)
  }

  @Test("detached HEAD では push と merge を問わない")
  func skipsBranchChecksForDetachedHead() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      #expect(commandArguments(arguments) == GitReadCommand.status().arguments)
      return .success(
        .init(
          exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: ""))
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: nil)

    let result = await inspector.inspect(detectedWorktrees: [try detectedRoot(branch: "main")])

    #expect(result.inspection.uncommittedChanges == .absent)
    #expect(result.inspection.unpushedCommits == .notApplicable)
    #expect(result.inspection.branchMerge == .notApplicable)
    #expect(result.defaultBranch == nil)
    #expect(result.failures.isEmpty)
  }

  @Test("ignored を変更に数えず、upstream より先行した commit を警告する")
  func ignoresIgnoredEntriesAndDetectsAheadCommit() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +2 -0\0! generated\0",
          stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(runner: try runner(results), targetBranch: "topic")

    let result = await inspector.inspect(detectedWorktrees: [])

    #expect(result.inspection.uncommittedChanges == .absent)
    #expect(result.inspection.unpushedCommits == .present)
    #expect(result.inspection.branchMerge == .unknown)
  }

  @Test("status の失敗後も merge 検査を返す")
  func preservesPartialSuccess() async throws {
    let statusError = ProcessRunnerError.timedOut(exitCode: nil, stdout: "", stderr: "")
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments:
        .failure(statusError)
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["merge-base", "--is-ancestor", "topic", "refs/remotes/origin/main"]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: "topic")

    let result = await inspector.inspect(detectedWorktrees: [])

    #expect(result.inspection.uncommittedChanges == .unknown)
    #expect(result.inspection.unpushedCommits == .unknown)
    #expect(result.inspection.branchMerge == .merged)
    #expect(result.failures.map(\.check) == [.uncommittedChanges, .unpushedCommits])
  }

  @Test("既定 branch 不明と merge-base の異常を unknown のまま返す")
  func keepsUnknownAndMergeErrors() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +1 -0\0",
          stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let noDefault = GitCloseSafetyInspector(runner: try runner(results), targetBranch: "topic")
    let unknown = await noDefault.inspect(detectedWorktrees: [])
    #expect(unknown.inspection.branchMerge == .unknown)
    #expect(unknown.failures.isEmpty)

    let mergeFailure = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +1 -0\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: "")),
      .success(.init(exitCode: 128, stdout: "", stderr: "fatal: bad revision\n")),
    ])
    let failedMerge = await GitCloseSafetyInspector(
      runner: try runner(mergeFailure), targetBranch: "topic"
    ).inspect(detectedWorktrees: [])
    #expect(failedMerge.inspection.branchMerge == .unknown)
    #expect(failedMerge.failures.map(\.check) == [.branchMerge])
  }

  private func runner(_ processRunner: any ProcessRunning) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: processRunner,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
      isExecutableFile: { _ in true })
  }

  private func detectedRoot(branch: String?) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git")), worktreePath: "/repo",
      branch: branch, isProjectRoot: true)
  }
}

private func commandArguments(_ arguments: [String]) -> [String] {
  Array(arguments.dropFirst(4))
}

private actor CloseInspectionProcessStub: ProcessRunning {
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

private actor CloseInspectionResultQueue: ProcessRunning {
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
