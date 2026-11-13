import TerminalCore
import Testing

@testable import Adapters

extension GitCloseSafetyInspectorTests {
  @Test("branch のある worktree では remote branch の問い合わせを撃たない")
  func skipsRemoteBranchQueryForAttachedHead() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      #expect(
        commandArguments(arguments) != GitReadCommand.remoteBranchesContainingHead().arguments)
      return .success(.init(exitCode: 0, stdout: "", stderr: ""))
    }
    let result = await GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic")
    ).inspect(projectRootBranch: "main")

    #expect(result.remoteBranchesContainingHead == .notApplicable)
  }

  @Test("remote branch の観測失敗は他の検査と failures に波及させない")
  func keepsRemoteBranchFailureIndependent() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.remoteBranchesContainingHead().arguments:
        .success(.init(exitCode: 128, stdout: "", stderr: "remote refs failed\n"))
      case GitReadCommand.stashList().arguments:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        .success(.init(exitCode: 0, stdout: "# branch.head (detached)\0", stderr: ""))
      }
    }
    let result = await GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: nil)
    ).inspect(projectRootBranch: "main")

    #expect(
      result.remoteBranchesContainingHead
        == .unknown(.commandFailed(exitCode: 128, stdout: "", stderr: "remote refs failed\n")))
    #expect(result.failures.isEmpty)
    #expect(result.report.inspection.uncommittedChanges == .absent)
    #expect(result.report.inspection.ignoredFiles == .absent)
    #expect(result.report.inspection.branchMerge == .unknown)
  }
}
