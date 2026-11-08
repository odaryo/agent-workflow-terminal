import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§3.4 stash 検査の失敗の独立性")
struct GitStashSafetyInspectorTests {
  @Test("stash list の失敗を他の検査へ波及させない", arguments: [false, true])
  func isolatesStashFailure(processFailure: Bool) async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0,
            stdout:
              "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -0\0",
            stderr: ""))
      case ["stash", "list", "--format=%gs"]:
        if processFailure {
          .failure(.outputLimitExceeded(limit: ProcessRunLimits.defaultOutputBytes))
        } else {
          .success(.init(exitCode: 128, stdout: "", stderr: "fatal: stash unavailable\n"))
        }
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        .success(.init(exitCode: 128, stdout: "", stderr: "unexpected command"))
      }
    }
    let target = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/topic")),
      worktreePath: "/repo/wt", branch: "topic", isProjectRoot: false)
    let runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: target.worktreePath), processRunner: stub,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
      isExecutableFile: { _ in true })

    let result = await GitCloseSafetyInspector(runner: runner, target: target)
      .inspect(projectRootBranch: nil)

    #expect(result.report.inspection.branchStashes == .unknown)
    #expect(result.report.inspection.uncommittedChanges == .absent)
    #expect(result.report.inspection.ignoredFiles == .absent)
    #expect(result.report.inspection.unpushedCommits == .absent)
    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.report.defaultBranch == .unresolved(reason: .originHeadMissing))
    #expect(result.failures.map(\.check) == [.branchStashes])
    let failure = try #require(result.failures.first)
    if processFailure {
      #expect(
        failure.reason
          == .git(.process(.outputLimitExceeded(limit: ProcessRunLimits.defaultOutputBytes))))
    } else {
      #expect(
        failure.reason
          == .git(.commandFailed(exitCode: 128, stdout: "", stderr: "fatal: stash unavailable\n")))
    }
  }
}
