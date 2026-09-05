import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("Close 前の git 安全確認 (設計書 §3.4)")
struct GitCloseSafetyInspectorTests {
  @Test("完全修飾された local branch ref を revision として受け付ける")
  func acceptsFullyQualifiedBranchRevision() {
    #expect(GitRevision("refs/heads/x")?.rawValue == "refs/heads/x")
  }

  @Test("refs/ で始まる短縮 branch 名にも refs/heads/ を付ける")
  func qualifiesBranchNameStartingWithRefs() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/refs/foo", "refs/heads/main"]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), targetBranch: "refs/foo")

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.defaultBranch == .projectRoot(branch: "main"))
    #expect(result.inspection.branchMerge == .unmerged)
    #expect(result.failures.isEmpty)
  }

  @Test("refs/heads/ で始まる短縮 branch 名も常に修飾する")
  func qualifiesBranchNameStartingWithRefsHeads() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0, stdout: "# branch.oid abc\0# branch.head refs/heads/x\0", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/refs/heads/x", "refs/heads/main"]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), targetBranch: "refs/heads/x")

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.inspection.branchMerge == .unmerged)
    #expect(result.failures.isEmpty)
  }

  @Test("untracked と upstream 不在を警告し、origin/HEAD へのマージを判定する")
  func inspectsWarningsAndOriginDefaultBranch() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0,
            stdout: "# branch.oid abc\0# branch.head topic\0? new.txt\0",
            stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/topic", "refs/remotes/origin/main"]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.inspection.uncommittedChanges == .present)
    #expect(result.inspection.ignoredFiles == .absent)
    #expect(result.inspection.unpushedCommits == .present)
    #expect(result.inspection.branchMerge == .merged)
    #expect(result.defaultBranch == .originHead(branch: "main"))
    #expect(result.failures.isEmpty)
  }

  @Test("origin/HEAD 不在なら Project Root の branch へフォールバックする")
  func fallsBackToProjectRootBranch() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0,
            stdout:
              "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -2\0",
            stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/topic", "refs/heads/main"]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.inspection.uncommittedChanges == .absent)
    #expect(result.inspection.ignoredFiles == .absent)
    #expect(result.inspection.unpushedCommits == .absent)
    #expect(result.inspection.branchMerge == .unmerged)
    #expect(result.defaultBranch == .projectRoot(branch: "main"))
    #expect(result.failures.isEmpty)
  }

  @Test("detached HEAD では push と merge を問わない")
  func skipsBranchChecksForDetachedHead() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      #expect(
        [GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments]
          .contains(commandArguments(arguments)))
      return .success(
        .init(
          exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: ""))
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: nil)

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.inspection.uncommittedChanges == .absent)
    #expect(result.inspection.ignoredFiles == .absent)
    #expect(result.inspection.unpushedCommits == .notApplicable)
    #expect(result.inspection.branchMerge == .notApplicable)
    #expect(result.defaultBranch == .unresolved(reason: .notNeededForDetachedHead))
    #expect(result.failures.isEmpty)
  }

  @Test("ignored を独立して警告し、upstream より先行した commit も警告する")
  func ignoresIgnoredEntriesAndDetectsAheadCommit() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +2 -0\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +2 -0\0! generated\0",
          stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(runner: try runner(results), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.inspection.uncommittedChanges == .absent)
    #expect(result.inspection.ignoredFiles == .present)
    #expect(result.inspection.unpushedCommits == .present)
    #expect(result.inspection.branchMerge == .unknown)
    #expect(result.defaultBranch == .unresolved(reason: .originHeadMissing))
  }

  @Test("ignored 側の出力上限超過を他の3検査へ波及させない")
  func isolatesIgnoredStatusFailure() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments:
        .success(
          .init(
            exitCode: 0,
            stdout:
              "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -0\0",
            stderr: ""))
      case GitReadCommand.status(includeIgnored: true).arguments:
        .failure(.outputLimitExceeded(limit: ProcessRunLimits.defaultOutputBytes))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/topic", "refs/remotes/origin/main"]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.inspection.uncommittedChanges == .absent)
    #expect(result.inspection.ignoredFiles == .unknown)
    #expect(result.inspection.unpushedCommits == .absent)
    #expect(result.inspection.branchMerge == .merged)
    #expect(result.failures.map(\.check) == [.ignoredFiles])
  }

  @Test("設定済み upstream の追跡 ref 消失を push 済みへ丸めない")
  func reportsMissingTrackingBranchAsKnownState() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0",
          stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(runner: try runner(results), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.inspection.unpushedCommits == .aheadUnknownWithoutTrackingReference)
    #expect(result.failures.isEmpty)
  }

  @Test("origin/HEAD の実行異常では Project Root へフォールバックしない")
  func doesNotFallbackAfterOriginHeadFailure() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(.init(exitCode: 128, stdout: "", stderr: "fatal: broken ref\n")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(runner: try runner(results), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.defaultBranch == .unresolved(reason: .lookupFailed))
    #expect(result.inspection.branchMerge == .unknown)
    #expect(result.failures.map(\.check) == [.branchMerge])
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: result.defaultBranch,
        merge: result.inspection.branchMerge))
  }

  @Test("解釈不能な origin/HEAD の値では Project Root へフォールバックしない")
  func doesNotFallbackAfterInvalidOriginHead() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "refs/heads/main\n", stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(runner: try runner(results), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(
      result.defaultBranch
        == .unresolved(reason: .invalidOriginHead("refs/heads/main")))
    #expect(result.inspection.branchMerge == .unknown)
    #expect(result.failures.isEmpty)
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: result.defaultBranch,
        merge: result.inspection.branchMerge))
  }

  @Test("実在する `(detached)` branch を upstream 無しとして警告する")
  func treatsNamedDetachedBranchAsBranch() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: "")),
      .success(
        .init(
          exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(
      runner: try runner(results), targetBranch: "(detached)")

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.inspection.unpushedCommits == .present)
  }

  @Test("status の失敗後も merge 検査を返す")
  func preservesPartialSuccess() async throws {
    let statusError = ProcessRunnerError.timedOut(exitCode: nil, stdout: "", stderr: "")
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments:
        .failure(statusError)
      case GitReadCommand.status(includeIgnored: true).arguments:
        .success(.init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/topic", "refs/remotes/origin/main"]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(runner: try runner(stub), targetBranch: "topic")

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.inspection.uncommittedChanges == .unknown)
    #expect(result.inspection.ignoredFiles == .absent)
    #expect(result.inspection.unpushedCommits == .unknown)
    #expect(result.inspection.branchMerge == .merged)
    #expect(
      result.failures.map(\.check) == [.uncommittedChanges, .unpushedCommits])
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
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +1 -0\0",
          stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let noDefault = GitCloseSafetyInspector(runner: try runner(results), targetBranch: "topic")
    let unknown = await noDefault.inspect(projectRootBranch: nil)
    #expect(unknown.inspection.branchMerge == .unknown)
    #expect(unknown.defaultBranch == .unresolved(reason: .originHeadMissing))
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
      .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: "")),
      .success(.init(exitCode: 128, stdout: "", stderr: "fatal: bad revision\n")),
    ])
    let failedMerge = await GitCloseSafetyInspector(
      runner: try runner(mergeFailure), targetBranch: "topic"
    ).inspect(projectRootBranch: nil)
    #expect(failedMerge.inspection.branchMerge == .unknown)
    #expect(failedMerge.failures.map(\.check) == [.branchMerge])
  }

  private func runner(_ processRunner: any ProcessRunning) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: processRunner,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
      isExecutableFile: { _ in true })
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
