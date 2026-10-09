import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

/// Close の確認に出す拒否・選択肢の可否・警告 (設計書 §3.4)。検査結果は `Adapters` の検査器を
/// 偽の git に対して走らせて作る —— report の初期化子は `package` で、`App` からは作れない。
@Suite("§3.4 Close の確認に出す内容")
struct WorktreeCloseReviewTests {
  @Test("merge の衝突中は選択肢1〜4のすべてを拒否し、途中の操作の完了か中止を案内する")
  func refusesWhileMerging() async throws {
    let review = try await review(CloseGit(mergeInProgress: true))

    let refusal = try #require(review.refusal)
    #expect(refusal == .operationInProgress([.merge]))
    let text = WorktreeCloseRefusalText(refusal, progressFailure: nil)
    #expect(text.reason.contains("merge"))
    #expect(text.guidance.contains("完了または中止"))
  }

  @Test("detached HEAD は選択肢1〜4のすべてを拒否する")
  func refusesDetachedHead() async throws {
    let review = try await review(CloseGit(), branch: nil)

    #expect(review.refusal == .detachedHeadIsNotClosable)
  }

  @Test("未commit の変更は選択肢3で警告し、確認すると --force で削除する計画になる")
  func warnsUncommittedChangesBeforeRemoval() async throws {
    let review = try await review(
      CloseGit(status: "# branch.oid abc\0# branch.head topic\0? new.txt\0"))

    #expect(review.refusal == nil)
    #expect(review.removalWarnings.contains { $0.contains("未commit") })
    #expect(review.requiresAcknowledgement(.removeWorktree))
    #expect(!review.requiresAcknowledgement(.hideFromUI))
    #expect(!review.requiresAcknowledgement(.terminateSession))
    let plan = try review.plan(.removeWorktree, acknowledged: true)
    #expect(plan.steps == [.terminateSession, .removeWorktree(force: true)])
  }

  @Test("警告が無ければ確認を求めず、--force も付けない")
  func removesWithoutForceWhenNothingToWarn() async throws {
    let review = try await review(CloseGit(ancestorMerged: true, upstreamInSync: true))

    #expect(review.removalWarnings.isEmpty)
    #expect(!review.requiresAcknowledgement(.removeWorktree))
    let plan = try review.plan(.removeWorktree, acknowledged: false)
    #expect(plan.steps == [.terminateSession, .removeWorktree(force: false)])
  }

  @Test("squash merge と判定した branch の削除では、強制削除することを明示して確認を求める")
  func statesForcedDeletionForSquashMerge() async throws {
    let review = try await review(CloseGit(squashMerged: true, upstreamInSync: true))

    #expect(review.unavailability(of: .deleteBranch) == nil)
    #expect(
      review.squashDeletionNotice
        == "git はこの branch を未マージと見なしているが、squash merge と判定したため強制削除する。")
    #expect(review.requiresAcknowledgement(.deleteBranch))
    #expect(!review.requiresAcknowledgement(.removeWorktree))
    let plan = try review.plan(.deleteBranch, acknowledged: true)
    #expect(
      plan.steps.last == .deleteBranch(name: "topic", tip: try #require(CommitObjectID(tipHex))))
  }

  @Test("マージされていない branch の削除は選べず、理由を出す")
  func disablesBranchDeletionForUnmergedBranch() async throws {
    let review = try await review(CloseGit())

    let reason = try #require(review.unavailability(of: .deleteBranch))
    #expect(reason.contains("マージされていない"))
    #expect(review.removalWarnings.contains { $0.contains("マージされていません") })
  }

  @Test("追跡 ref の無い upstream を、追跡先が消えたとは言わない")
  func describesMissingTrackingReferenceWithoutClaimingItWasDeleted() async throws {
    let review = try await review(
      CloseGit(status: "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0"))

    let warning = try #require(review.removalWarnings.first { $0.contains("追跡 ref") })
    #expect(warning.contains("判定できません"))
    #expect(!warning.contains("消え"))
  }

  @Test("tmux を使えない起動では、session を終了する選択肢2〜4を選べない")
  func disablesSessionOptionsWithoutTmux() async throws {
    let review = try await review(CloseGit(ancestorMerged: true), canTerminateSessions: false)

    #expect(review.unavailability(of: .hideFromUI) == nil)
    for option in [WorktreeCloseOption.terminateSession, .removeWorktree, .deleteBranch] {
      #expect(review.unavailability(of: option) != nil)
    }
  }

  @Test("実行直前の読み直しで中止したら、何も実行しなかったことと理由を出す")
  func describesAbandonedExecution() {
    let result = WorktreeCloseResultText(
      .abandoned(.branchChanged(planned: "topic", current: "other")))

    #expect(!result.closedWorktree)
    #expect(result.headline.contains("何も実行しませんでした"))
    #expect(result.details == ["HEAD が「topic」から「other」へ切り替わっています。"])
  }

  private func review(
    _ git: CloseGit, branch: String? = "topic", canTerminateSessions: Bool = true
  ) async throws -> WorktreeCloseReview {
    let target = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/nonexistent-awt/.git/worktrees/topic")),
      worktreePath: "/nonexistent-awt/topic", branch: branch, isProjectRoot: false)
    let executable = [URL(fileURLWithPath: "/usr/bin/true")]
    let progress = await try GitWorktreeProgressInspector(
      target: target, processRunner: git, executableCandidates: executable
    ).inspect()
    let safety = await try GitCloseSafetyInspector(
      target: target, processRunner: git, executableCandidates: executable
    ).inspect(projectRootBranch: "main")
    return WorktreeCloseReview(
      target: target, progress: progress, safety: safety,
      canTerminateSessions: canTerminateSessions)
  }
}

private let tipHex = String(repeating: "a", count: 40)

/// branch `topic` を持つ worktree に対する git。既定は「変更なし・upstream なし・未マージ」。
private struct CloseGit: ProcessRunning {
  var status = "# branch.oid abc\0# branch.head topic\0"
  var mergeInProgress = false
  var ancestorMerged = false
  var squashMerged = false
  var upstreamInSync = false

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    let command = Array(arguments.drop { $0 != "--no-pager" }.dropFirst())
    let mergeBase = String(repeating: "e", count: 40)
    switch command.first {
    case "status":
      let status =
        upstreamInSync
        ? "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -0\0"
        : status
      return .init(exitCode: 0, stdout: status, stderr: "")
    case "symbolic-ref":
      return .init(exitCode: 1, stdout: "", stderr: "")
    case "rev-parse":
      return revParse(command.last)
    case "merge-base" where command.dropFirst().first == "--is-ancestor":
      return .init(exitCode: ancestorMerged ? 0 : 1, stdout: "", stderr: "")
    case "merge-base":
      return .init(exitCode: 0, stdout: mergeBase + "\n", stderr: "")
    case "log":
      let date = "2026-10-08T00:00:00+09:00"
      let record = [
        String(repeating: "d", count: 40), "ddddddd", String(repeating: "f", count: 40), "a",
        "a@example.com", date, "c", "c@example.com", date, "squash topic", "",
      ]
      return .init(exitCode: 0, stdout: record.joined(separator: "\u{1F}") + "\0", stderr: "")
    case "diff":
      let isBranchChange = command.contains { $0.hasPrefix(mergeBase) }
      return .init(
        exitCode: 0, stdout: squashMerged || isBranchChange ? "same-change" : "other-change",
        stderr: "")
    default:
      throw .launchFailed(executableURL: executableURL, message: "unexpected: \(command)")
    }
  }

  private func revParse(_ revision: String?) -> ProcessRunResult {
    switch revision {
    case "MERGE_HEAD": .init(exitCode: mergeInProgress ? 0 : 1, stdout: "", stderr: "")
    case "refs/heads/topic": .init(exitCode: 0, stdout: tipHex + "\n", stderr: "")
    case "refs/heads/main":
      .init(exitCode: 0, stdout: String(repeating: "b", count: 40) + "\n", stderr: "")
    default: .init(exitCode: 1, stdout: "", stderr: "")
    }
  }
}
