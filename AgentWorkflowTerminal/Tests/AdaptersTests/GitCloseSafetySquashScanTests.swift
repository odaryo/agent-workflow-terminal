import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// ancestor 判定に現れない squash merge の走査 (§3.4) のうち、**判定できなかった**経路を固定する。
/// 実 git では起こしにくい失敗ばかりなので stub で組む。実 git 側は
/// `GitSquashMergeCloseIntegrationTests` が持つ。
@Suite("§3.4 squash merge 走査が判定できないとき")
struct GitCloseSafetySquashScanTests {
  @Test("squash 走査の実行異常を unmerged にも merged にも丸めず unknown にする")
  func reportsSquashScanFailureAsUnknown() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(.init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/topic", "refs/heads/main"]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case let arguments where arguments.first == "diff":
        .success(.init(exitCode: 128, stdout: "", stderr: "fatal: bad revision\n"))
      default:
        squashScanWithoutCandidates(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.failures.map(\.check) == [.branchMerge])
  }

  @Test("squash 走査で読む log の解釈失敗も unknown にする")
  func reportsSquashScanLogParseFailureAsUnknown() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(.init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["merge-base", "--is-ancestor", "refs/heads/topic", "refs/heads/main"]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case let arguments where arguments.first == "log":
        .success(.init(exitCode: 0, stdout: "not-a-commit-record\0", stderr: ""))
      default:
        squashScanWithoutCandidates(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: "main")

    // 走査を完遂できていない以上、候補が見つからなかったのか読めなかったのかを区別できない。
    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.failures.count == 1)
    if case .logParse(let failures) = try #require(result.failures.first).reason {
      #expect(failures.count == 1)
    } else {
      Issue.record("log の解釈失敗が理由として残っていない")
    }
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

/// ancestor 判定が rc 1 を返した後に走る squash merge 走査 (§3.4) への応答。既定 branch 側に
/// merge-base より後の commit が1つも無い形なので、突き合わせる相手がおらず `.unmerged` になる。
/// 走査に関係しない command はここでは扱わず、呼び出し側の想定外として失敗させる。
func squashScanWithoutCandidates(
  _ arguments: [String]
) -> Result<ProcessRunResult, ProcessRunnerError> {
  let oid = String(repeating: "a", count: 40)
  switch arguments.first {
  case "merge-base" where arguments.dropFirst().first != "--is-ancestor":
    return .success(.init(exitCode: 0, stdout: oid + "\n", stderr: ""))
  case "diff":
    return .success(
      .init(exitCode: 0, stdout: ":000000 100644 \(oid) \(oid) A\0a.txt\0", stderr: ""))
  case "log":
    return .success(.init(exitCode: 0, stdout: "", stderr: ""))
  default:
    return .failure(.launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: ""))
  }
}
