import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// merge 判定に使う branch 先端の解決 (§3.4、Issue #359)。判定と計画が同じ commit を指すことは
/// 実 git の `GitSquashMergeCloseIntegrationTests` / `GitCloseProgressIntegrationTests` が固定する。
@Suite("§3.4 merge 判定に使う branch 先端")
struct GitCloseSafetyTipTests {
  /// 判定は ref 名ではなく1回読んだ OID に対して行い、その OID を計画へ渡す (Issue #359)。
  /// 読めなければ、どの commit について判定したのかが言えないので `.unknown` にする。
  @Test(
    "branch の先端を読めなければ merge 判定を unknown にする",
    arguments: [
      (
        ProcessRunResult(exitCode: 1, stdout: "", stderr: ""),
        GitCloseSafetyInspectionFailure.Reason.git(
          .commandFailed(exitCode: 1, stdout: "", stderr: ""))
      ),
      (ProcessRunResult(exitCode: 0, stdout: "abc\n", stderr: ""), .invalidRevision("abc\n")),
    ])
  func reportsUnknownWhenTheTipCannotBeResolved(
    tip: ProcessRunResult, reason: GitCloseSafetyInspectionFailure.Reason
  ) async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(.init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["rev-parse", "--verify", "--quiet", "refs/heads/topic"]:
        .success(tip)
      default:
        .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.failures == [.init(check: .branchMerge, reason: reason)])
  }

  private func runner(_ processRunner: any ProcessRunning) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: processRunner,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
      isExecutableFile: { _ in true })
  }

  private func target(branch: String) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/topic")),
      worktreePath: "/repo/wt", branch: branch, isProjectRoot: false)
  }
}
