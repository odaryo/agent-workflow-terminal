import TerminalCore
import Testing

@Suite("Close の実行計画 (設計書 §3.4)")
struct WorktreeClosePlanTests {
  @Test("UI だけの Close は何も実行しない")
  func planForHideFromUIHasNoStep() throws {
    let plan = try planWorktreeClose(
      worktree: try worktree(), choice: .hideFromUI,
      defaultBranch: .originHead(branch: "main"),
      confirmation: nil)

    #expect(plan.steps.isEmpty)
  }

  @Test("session 終了だけの Close は検査結果を要求しない")
  func planForSessionTerminationNeedsNoConfirmation() throws {
    let plan = try planWorktreeClose(
      worktree: try worktree(), choice: .terminateSession(.keepWorktree),
      defaultBranch: .originHead(branch: "main"), confirmation: nil)

    #expect(plan.steps == [.terminateSession])
  }

  @Test("削除を伴う Close は検査結果の確認なしには計画できない")
  func planRejectsRemovalWithoutConfirmation() throws {
    let target = try worktree()
    #expect(throws: WorktreeClosePlanError.removalNotConfirmed) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.keepBranch)),
        defaultBranch: .originHead(branch: "main"), confirmation: nil)
    }
    #expect(throws: WorktreeClosePlanError.removalNotConfirmed) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
        defaultBranch: .originHead(branch: "main"), confirmation: nil)
    }
  }

  @Test(
    "--force は未commit変更を承知で続行したときにだけ付く",
    arguments: [
      (
        UncommittedChangesStatus.absent, WorktreeRemovalConfirmation.Continuation.withoutForce,
        false
      ),
      (.absent, .forcingAcknowledgedWarnings, false),
      (.present, .withoutForce, false),
      (.present, .forcingAcknowledgedWarnings, true),
      (.unknown, .withoutForce, false),
      (.unknown, .forcingAcknowledgedWarnings, true),
    ])
  func forceRequiresAcknowledgedUncommittedChanges(
    uncommitted: UncommittedChangesStatus,
    continuation: WorktreeRemovalConfirmation.Continuation,
    expectsForce: Bool
  ) throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: uncommitted), continuation: continuation)

    let plan = try planWorktreeClose(
      worktree: try worktree(), choice: .terminateSession(.removeWorktree(.keepBranch)),
      defaultBranch: .originHead(branch: "main"), confirmation: confirmation)

    #expect(plan.steps == [.terminateSession, .removeWorktree(force: expectsForce)])
  }

  @Test("ignored ファイルだけでは --force を付けない")
  func ignoredFilesAloneDoNotForce() throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, ignored: .present),
      continuation: .forcingAcknowledgedWarnings)

    let plan = try planWorktreeClose(
      worktree: try worktree(), choice: .terminateSession(.removeWorktree(.keepBranch)),
      defaultBranch: .originHead(branch: "main"), confirmation: confirmation)

    #expect(plan.steps == [.terminateSession, .removeWorktree(force: false)])
  }

  @Test("マージ済み branch の削除は session 終了・worktree 削除の後に続く")
  func planForBranchDeletionOrdersStepsAfterRemoval() throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .merged), continuation: .withoutForce)

    let plan = try planWorktreeClose(
      worktree: try worktree(), choice: .terminateSession(.removeWorktree(.deleteBranch)),
      defaultBranch: .originHead(branch: "main"), confirmation: confirmation)

    #expect(
      plan.steps == [
        .terminateSession, .removeWorktree(force: false), .deleteBranch(name: "topic"),
      ])
  }

  @Test(
    "検査を通らない branch 削除は計画にならない",
    arguments: [
      (BranchMergeStatus.unmerged, "topic", DefaultBranchResolution.originHead(branch: "main")),
      (.unknown, "topic", .originHead(branch: "main")),
      (.notApplicable, "topic", .originHead(branch: "main")),
      (.merged, "main", .originHead(branch: "main")),
      (.merged, "topic", .unresolved(reason: .originHeadMissing)),
    ])
  func planRejectsBranchDeletionThatInspectionDoesNotPermit(
    merge: BranchMergeStatus,
    branch: String,
    defaultBranch: DefaultBranchResolution
  ) throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: merge), continuation: .withoutForce)

    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        worktree: try worktree(branch: branch),
        choice: .terminateSession(.removeWorktree(.deleteBranch)),
        defaultBranch: defaultBranch, confirmation: confirmation)
    }
  }

  @Test("detached HEAD では branch 削除を計画できない")
  func planRejectsBranchDeletionForDetachedHead() throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .notApplicable),
      continuation: .withoutForce)

    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        worktree: try worktree(branch: nil),
        choice: .terminateSession(.removeWorktree(.deleteBranch)),
        defaultBranch: .originHead(branch: "main"), confirmation: confirmation)
    }
  }

  @Test("refs/ で始まる branch 値では選択肢4を提供しない (Issue #142 の暫定 guard)")
  func withholdsBranchDeletionForReferenceLikeBranchValue() throws {
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "refs/foo/bar", defaultBranch: .originHead(branch: "main"), merge: .merged))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "refs/heads/topic", defaultBranch: .originHead(branch: "main"),
        merge: .merged))
    // 途中に refs/ を含むだけの通常の branch 名は落とさない。
    #expect(
      isBranchDeletionAvailable(
        targetBranch: "feat/refs/x", defaultBranch: .originHead(branch: "main"), merge: .merged))

    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .merged), continuation: .withoutForce)
    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        worktree: try worktree(branch: "refs/foo/bar"),
        choice: .terminateSession(.removeWorktree(.deleteBranch)),
        defaultBranch: .originHead(branch: "main"), confirmation: confirmation)
    }
  }

  @Test("どの選択肢の計画も対象の worktree を持つ")
  func planCarriesTheTargetWorktree() throws {
    let target = try worktree()
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .merged), continuation: .withoutForce)
    let choices: [WorktreeCloseChoice] = [
      .hideFromUI, .terminateSession(.keepWorktree),
      .terminateSession(.removeWorktree(.keepBranch)),
      .terminateSession(.removeWorktree(.deleteBranch)),
    ]

    for choice in choices {
      let plan = try planWorktreeClose(
        worktree: target, choice: choice,
        defaultBranch: .originHead(branch: "main"), confirmation: confirmation)

      #expect(plan.worktree == target.identity)
    }
  }

  @Test("対象が違えば、同じ step 列でも別の計画になる")
  func plansForDifferentWorktreesAreNotEqual() throws {
    func plan(_ target: DetectedWorktree) throws -> WorktreeClosePlan {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.keepWorktree),
        defaultBranch: .originHead(branch: "main"), confirmation: nil)
    }

    let first = try plan(try worktree("/repo/.git/worktrees/feature-a"))
    let second = try plan(try worktree("/repo/.git/worktrees/feature-b"))

    #expect(first.steps == second.steps)
    #expect(first != second)
  }

  /// 削除する branch 名を安定 ID と**別引数**で受け取れると、worktree A の Close として
  /// worktree B の branch を消す計画が作れる。`DetectedWorktree` ごと受け取るのがその封じ手なので、
  /// 計画に載る branch 名が渡した `DetectedWorktree` のものであることを確かめる。
  @Test("削除する branch 名は対象 worktree のものを使う")
  func planTakesTheBranchNameFromTheTargetWorktree() throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .merged), continuation: .withoutForce)

    let plan = try planWorktreeClose(
      worktree: try worktree("/repo/.git/worktrees/feature-b", branch: "feature-b"),
      choice: .terminateSession(.removeWorktree(.deleteBranch)),
      defaultBranch: .originHead(branch: "main"), confirmation: confirmation)

    #expect(plan.steps.last == .deleteBranch(name: "feature-b"))
  }

  /// git は main working tree の削除を拒否するが (git 2.50.1 実測: `--force` の有無にかかわらず
  /// rc=128 / `fatal: '<path>' is a main working tree`)、その拒否は計画の順序上 `terminateSession`
  /// を撃った後に起きる。Project Root の常設 session (§2.3) を落としてからでは遅いので、
  /// **どの選択肢でも**計画段階で止める。`.hideFromUI` も例外にしない —— §2.3 上 Project Root は
  /// Active/Inactive を持たないので、UI から隠す Close も定義されない。
  @Test(
    "Project Root の Close はどの選択肢でも計画段階で拒否する",
    arguments: [
      WorktreeCloseChoice.hideFromUI, .terminateSession(.keepWorktree),
      .terminateSession(.removeWorktree(.keepBranch)),
      .terminateSession(.removeWorktree(.deleteBranch)),
    ])
  func planRejectsClosingTheProjectRoot(choice: WorktreeCloseChoice) throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .merged), continuation: .withoutForce)

    #expect(throws: WorktreeClosePlanError.projectRootIsNotClosable) {
      try planWorktreeClose(
        worktree: try worktree("/repo/.git", branch: "main", isProjectRoot: true), choice: choice,
        defaultBranch: .originHead(branch: "main"), confirmation: confirmation)
    }
  }

  private func worktree(
    _ identity: String = "/repo/.git/worktrees/feature-a",
    branch: String? = "topic",
    isProjectRoot: Bool = false
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: identity)),
      worktreePath: "/repo/wt", branch: branch, isProjectRoot: isProjectRoot)
  }

  private func inspection(
    uncommitted: UncommittedChangesStatus,
    ignored: IgnoredFilesStatus = .absent,
    merge: BranchMergeStatus = .unmerged
  ) -> WorktreeCloseInspection {
    WorktreeCloseInspection(
      uncommittedChanges: uncommitted, ignoredFiles: ignored, unpushedCommits: .absent,
      branchMerge: merge)
  }
}
