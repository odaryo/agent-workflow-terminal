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

  @Test("branch 名で作られた stash の件数と削除後の扱いを警告する")
  func warnsBranchStashesBeforeRemoval() async throws {
    let review = try await review(
      CloseGit(
        ancestorMerged: true, upstreamInSync: true,
        stashOutput: "WIP on topic: abc first\nOn topic: second\n"))

    #expect(review.safety.report.inspection.branchStashes == .present(count: 2))
    #expect(
      review.removalWarnings == [
        "branch topic の名前で作られた stash が 2 件あります。worktree を消しても stash は残りますが、この worktree からは辿れなくなります。"
      ])
    #expect(review.requiresAcknowledgement(.removeWorktree))
    #expect(review.requiresAcknowledgement(.deleteBranch))
  }

  @Test("stash を確認できなければ警告して確認を求める")
  func warnsUnknownBranchStashes() async throws {
    let review = try await review(
      CloseGit(ancestorMerged: true, upstreamInSync: true, stashExitCode: 128))

    #expect(review.safety.report.inspection.branchStashes == .unknown)
    #expect(review.removalWarnings == ["stash があるかを確認できませんでした。"])
    #expect(review.requiresAcknowledgement(.removeWorktree))
    #expect(review.requiresAcknowledgement(.deleteBranch))
  }

  @Test(
    "stash 無し・対象外は警告を足さない",
    arguments: [BranchStashStatus.absent, .notApplicable])
  func doesNotWarnForAbsentOrInapplicableStashes(stashes: BranchStashStatus) async throws {
    let review = try await review(CloseGit(ancestorMerged: true, upstreamInSync: true))
    let inspection = WorktreeCloseInspection(
      uncommittedChanges: .absent, ignoredFiles: .absent, branchStashes: stashes,
      unpushedCommits: .absent, branchMerge: review.safety.report.inspection.branchMerge)

    #expect(review.removalWarnings(for: inspection).isEmpty)
  }

  @Test("branch を特定できない stash は別の文言で知らせる")
  func warnsUndeterminedStashes() async throws {
    let review = try await review(
      CloseGit(
        ancestorMerged: true, upstreamInSync: true,
        stashOutput: "autostash\nWIP on (no branch): abc x\n"))

    #expect(review.safety.report.inspection.branchStashes == .absent)
    #expect(review.safety.report.inspection.undeterminedStashCount == 2)
    #expect(
      review.removalWarnings == [
        "branch を特定できない stash が 2 件あります。この worktree の作業かどうかは件名から判断できません。"
      ])
  }

  @Test("stash の警告は ignored の後、未push の前に出す")
  func ordersStashWarningAfterIgnoredFiles() async throws {
    let review = try await review(
      CloseGit(
        status: "# branch.oid abc\0# branch.head topic\0! .env\0",
        stashOutput: "On topic: saved\n"))

    // CloseGit は2回の status に同じ出力を返すので、`! .env` は未commit の検査にも当たる。
    try #require(review.removalWarnings.count == 5, "\(review.removalWarnings)")
    #expect(review.removalWarnings[0].contains("未commit"))
    #expect(review.removalWarnings[1].contains("gitignore"))
    #expect(review.removalWarnings[2].contains("stash が 1 件"))
    #expect(review.removalWarnings[3].contains("push していない"))
    #expect(review.removalWarnings[4].contains("マージされていません"))
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

  @Test("lock は選択肢1・2を許可し、3・4では理由と unlock を案内する", arguments: ["持ち出し中\n再接続待ち", ""])
  func disablesRemovalForLockedWorktree(reason: String) async throws {
    let review = try await review(CloseGit(ancestorMerged: true), lockReason: reason)

    #expect(review.refusal == nil)
    for option in [WorktreeCloseOption.hideFromUI, .terminateSession] {
      #expect(review.unavailability(of: option) == nil)
      _ = try review.plan(option, acknowledged: false)
    }
    for option in [WorktreeCloseOption.removeWorktree, .deleteBranch] {
      let text = try #require(review.unavailability(of: option))
      #expect(text.contains("lock されています"))
      #expect(text.contains("shell で git worktree unlock"))
      #expect(text.contains("理由:") == !reason.isEmpty)
      if !reason.isEmpty {
        #expect(text.contains("持ち出し中 再接続待ち"))
      }
    }
  }

  @Test("lock かつ未マージでも選択肢4には lock の理由を出す")
  func prioritizesLockOverUnmergedBranch() async throws {
    let review = try await review(CloseGit(), lockReason: "保管中")

    let text = try #require(review.unavailability(of: .deleteBranch))
    #expect(text.contains("lock されています (理由: 保管中)"))
    #expect(!text.contains("マージされていない"))
  }

  @Test("submodule は選択肢3・4を拒否し shell での削除を案内する", arguments: [true, false])
  func disablesRemovalForSubmodules(withPaths: Bool) async throws {
    let review = try await review(
      CloseGit(ancestorMerged: true), submodulePaths: withPaths ? ["libs/one", "libs/two"] : [],
      hasAdministrativeModules: !withPaths)

    #expect(review.refusal == nil)
    #expect(review.unavailability(of: .hideFromUI) == nil)
    #expect(review.unavailability(of: .terminateSession) == nil)
    for option in [WorktreeCloseOption.removeWorktree, .deleteBranch] {
      let text = try #require(review.unavailability(of: option))
      #expect(text.contains("submodule を含む worktree は削除できません"))
      #expect(text.contains("submodule の中の変更を確かめたうえで、shell で削除"))
      #expect(text.contains("(libs/one、libs/two)") == withPaths)
      #expect(text.contains("()") == false)
    }
  }

  @Test("削除の妨げを観測できなければ3・4だけを拒否し、読み取り失敗の理由を出す")
  func disablesRemovalWhenObstaclesUnknown() async throws {
    let review = try await review(CloseGit(ancestorMerged: true, indexReadFails: true))

    #expect(review.refusal == nil)
    #expect(review.unavailability(of: .hideFromUI) == nil)
    #expect(review.unavailability(of: .terminateSession) == nil)
    for option in [WorktreeCloseOption.removeWorktree, .deleteBranch] {
      let text = try #require(review.unavailability(of: option))
      #expect(text.contains("削除を妨げる条件 (lock・submodule) を確認できませんでした:"))
      #expect(text.contains("index unavailable"))
    }
    let text = WorktreeCloseRefusalText(
      .removalObstaclesUnknown, progressFailure: nil,
      removalObstaclesFailure: review.progress.removalObstaclesFailure)
    #expect(text.reason.contains("index unavailable"))
  }

  @Test("実行直前に lock が見つかったら、未実行と理由・unlock の案内を出す")
  func describesExecutionAbandonedForLock() {
    let result = WorktreeCloseResultText(.abandoned(.worktreeLocked(reason: "保管中")))

    #expect(!result.closedWorktree)
    #expect(result.headline.contains("何も実行しませんでした"))
    #expect(
      result.details == [
        "この worktree は lock されています (理由: 保管中)。shell で git worktree unlock してから Close してください。"
      ])
  }

  private func review(
    _ git: CloseGit, branch: String? = "topic", canTerminateSessions: Bool = true,
    lockReason: String? = nil, submodulePaths: [String] = [], hasAdministrativeModules: Bool = false
  ) async throws -> WorktreeCloseReview {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
    let administrative = root.appending(path: "admin")
    let worktree = root.appending(path: "worktree")
    try manager.createDirectory(at: administrative, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    if let lockReason {
      try lockReason.write(
        to: administrative.appending(path: "locked"), atomically: true, encoding: .utf8)
    }
    if hasAdministrativeModules {
      try manager.createDirectory(
        at: administrative.appending(path: "modules"), withIntermediateDirectories: true)
    }
    for path in submodulePaths {
      try manager.createDirectory(
        at: worktree.appending(path: path).appending(path: ".git"),
        withIntermediateDirectories: true)
    }
    var git = git
    git.submodulePaths = submodulePaths
    let target = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: administrative.path)),
      worktreePath: worktree.path, branch: branch, isProjectRoot: false)
    let executable = [URL(fileURLWithPath: "/usr/bin/true")]
    let progress = try await GitWorktreeProgressInspector(
      target: target, processRunner: git, executableCandidates: executable
    ).inspect()
    let safety = try await GitCloseSafetyInspector(
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
  var indexReadFails = false
  var submodulePaths: [String] = []
  var stashOutput = ""
  var stashExitCode: Int32 = 0

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    let command = Array(arguments.drop { $0 != "--no-pager" }.dropFirst())
    let mergeBase = String(repeating: "e", count: 40)
    switch command.first {
    case "ls-files":
      return .init(
        exitCode: indexReadFails ? 128 : 0,
        stdout: submodulePaths.map { "160000 \(tipHex) 0\t\($0)\0" }.joined(),
        stderr: indexReadFails ? "index unavailable" : "")
    case "status":
      let status =
        upstreamInSync
        ? "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -0\0"
        : status
      return .init(exitCode: 0, stdout: status, stderr: "")
    case "symbolic-ref":
      return .init(exitCode: 1, stdout: "", stderr: "")
    case "stash" where command.dropFirst().first == "list":
      return .init(exitCode: stashExitCode, stdout: stashOutput, stderr: "")
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
