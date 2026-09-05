import TerminalCore
import Testing

@Suite("Close の実行計画 (設計書 §3.4)")
struct WorktreeClosePlanTests {
  @Test("UI だけの Close は何も実行しない")
  func planForHideFromUIHasNoStep() throws {
    let plan = try planWorktreeClose(
      choice: .hideFromUI, branch: "topic", defaultBranch: .originHead(branch: "main"),
      confirmation: nil)

    #expect(plan.steps.isEmpty)
  }

  @Test("session 終了だけの Close は検査結果を要求しない")
  func planForSessionTerminationNeedsNoConfirmation() throws {
    let plan = try planWorktreeClose(
      choice: .terminateSession(.keepWorktree), branch: "topic",
      defaultBranch: .originHead(branch: "main"), confirmation: nil)

    #expect(plan.steps == [.terminateSession])
  }

  @Test("削除を伴う Close は検査結果の確認なしには計画できない")
  func planRejectsRemovalWithoutConfirmation() {
    #expect(throws: WorktreeClosePlanError.removalNotConfirmed) {
      try planWorktreeClose(
        choice: .terminateSession(.removeWorktree(.keepBranch)), branch: "topic",
        defaultBranch: .originHead(branch: "main"), confirmation: nil)
    }
    #expect(throws: WorktreeClosePlanError.removalNotConfirmed) {
      try planWorktreeClose(
        choice: .terminateSession(.removeWorktree(.deleteBranch)), branch: "topic",
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
      choice: .terminateSession(.removeWorktree(.keepBranch)), branch: "topic",
      defaultBranch: .originHead(branch: "main"), confirmation: confirmation)

    #expect(plan.steps == [.terminateSession, .removeWorktree(force: expectsForce)])
  }

  @Test("ignored ファイルだけでは --force を付けない")
  func ignoredFilesAloneDoNotForce() throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, ignored: .present),
      continuation: .forcingAcknowledgedWarnings)

    let plan = try planWorktreeClose(
      choice: .terminateSession(.removeWorktree(.keepBranch)), branch: "topic",
      defaultBranch: .originHead(branch: "main"), confirmation: confirmation)

    #expect(plan.steps == [.terminateSession, .removeWorktree(force: false)])
  }

  @Test("マージ済み branch の削除は session 終了・worktree 削除の後に続く")
  func planForBranchDeletionOrdersStepsAfterRemoval() throws {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .merged), continuation: .withoutForce)

    let plan = try planWorktreeClose(
      choice: .terminateSession(.removeWorktree(.deleteBranch)), branch: "topic",
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
  ) {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: merge), continuation: .withoutForce)

    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        choice: .terminateSession(.removeWorktree(.deleteBranch)), branch: branch,
        defaultBranch: defaultBranch, confirmation: confirmation)
    }
  }

  @Test("detached HEAD では branch 削除を計画できない")
  func planRejectsBranchDeletionForDetachedHead() {
    let confirmation = WorktreeRemovalConfirmation(
      inspection: inspection(uncommitted: .absent, merge: .notApplicable),
      continuation: .withoutForce)

    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        choice: .terminateSession(.removeWorktree(.deleteBranch)), branch: nil,
        defaultBranch: .originHead(branch: "main"), confirmation: confirmation)
    }
  }

  @Test("refs/ で始まる branch 値では選択肢4を提供しない (Issue #142 の暫定 guard)")
  func withholdsBranchDeletionForReferenceLikeBranchValue() {
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
        choice: .terminateSession(.removeWorktree(.deleteBranch)), branch: "refs/foo/bar",
        defaultBranch: .originHead(branch: "main"), confirmation: confirmation)
    }
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
