import TerminalCore
import Testing

@Suite("Close の実行計画 (設計書 §3.4)")
struct WorktreeClosePlanTests {
  @Test("UI だけの Close は何も実行しない")
  func planForHideFromUIHasNoStep() throws {
    let plan = try planWorktreeClose(
      worktree: try worktree(), choice: .hideFromUI, confirmation: nil)

    #expect(plan.steps.isEmpty)
  }

  @Test("session 終了だけの Close は検査結果を要求しない")
  func planForSessionTerminationNeedsNoConfirmation() throws {
    let plan = try planWorktreeClose(
      worktree: try worktree(), choice: .terminateSession(.keepWorktree), confirmation: nil)

    #expect(plan.steps == [.terminateSession])
  }

  @Test("削除を伴う Close は検査結果の確認なしには計画できない")
  func planRejectsRemovalWithoutConfirmation() throws {
    let target = try worktree()
    #expect(throws: WorktreeClosePlanError.removalNotConfirmed) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.keepBranch)),
        confirmation: nil)
    }
    #expect(throws: WorktreeClosePlanError.removalNotConfirmed) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
        confirmation: nil)
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
    let target = try worktree()

    let plan = try planWorktreeClose(
      worktree: target, choice: .terminateSession(.removeWorktree(.keepBranch)),
      confirmation: confirmation(
        for: target, uncommitted: uncommitted, continuation: continuation))

    #expect(plan.steps == [.terminateSession, .removeWorktree(force: expectsForce)])
  }

  @Test("ignored ファイルだけでは --force を付けない")
  func ignoredFilesAloneDoNotForce() throws {
    let target = try worktree()

    let plan = try planWorktreeClose(
      worktree: target, choice: .terminateSession(.removeWorktree(.keepBranch)),
      confirmation: confirmation(
        for: target, ignored: .present, continuation: .forcingAcknowledgedWarnings))

    #expect(plan.steps == [.terminateSession, .removeWorktree(force: false)])
  }

  @Test("マージ済み branch の削除は session 終了・worktree 削除の後に続く")
  func planForBranchDeletionOrdersStepsAfterRemoval() throws {
    let target = try worktree()

    let plan = try planWorktreeClose(
      worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
      confirmation: confirmation(for: target, merge: .merged))

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
    let target = try worktree(branch: branch)

    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
        confirmation: confirmation(for: target, merge: merge, defaultBranch: defaultBranch))
    }
  }

  /// 選択肢4の可否は `targetBranch != defaultBranch` を問うが、その既定 branch は
  /// **未merge検査を計算したのと同じもの**でなければならない。別々に渡せると「`main` へマージ
  /// 済み」という判定を「既定 branch は `develop`」という解決結果と組にでき、`main` へのマージ
  /// だけを根拠に別の branch を消す計画が立つ。既定 branch が確認から来ることを固定する。
  @Test("既定 branch は未merge検査と同じ確認から取る")
  func takesTheDefaultBranchFromTheConfirmation() throws {
    let target = try worktree(branch: "develop")

    let plan = try planWorktreeClose(
      worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
      confirmation: confirmation(for: target, merge: .merged))

    #expect(plan.steps.last == .deleteBranch(name: "develop"))
    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
        confirmation: confirmation(
          for: target, merge: .merged, defaultBranch: .originHead(branch: "develop")))
    }
  }

  @Test("detached HEAD では branch 削除を計画できない")
  func planRejectsBranchDeletionForDetachedHead() throws {
    let target = try worktree(branch: nil)

    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
        confirmation: confirmation(for: target, merge: .notApplicable))
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

    let target = try worktree(branch: "refs/foo/bar")
    #expect(throws: WorktreeClosePlanError.branchDeletionNotPermitted) {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
        confirmation: confirmation(for: target, merge: .merged))
    }
  }

  @Test("どの選択肢の計画も対象の worktree を持つ")
  func planCarriesTheTargetWorktree() throws {
    let target = try worktree()
    let choices: [WorktreeCloseChoice] = [
      .hideFromUI, .terminateSession(.keepWorktree),
      .terminateSession(.removeWorktree(.keepBranch)),
      .terminateSession(.removeWorktree(.deleteBranch)),
    ]

    for choice in choices {
      let plan = try planWorktreeClose(
        worktree: target, choice: choice,
        confirmation: confirmation(for: target, merge: .merged))

      #expect(plan.worktree == target.identity)
    }
  }

  /// **`--force` は git が拒否する唯一の条件を無効化するフラグである。** git 2.50.1 実測
  /// (`mktemp -d` 配下の使い捨て repository): 未commit変更と untracked ファイルを持つ worktree
  /// への `worktree remove -- <path>` は rc=128 /
  /// `fatal: '<path>' contains modified or untracked files, use --force to delete it` で止まるが、
  /// `--force` を足すと rc=0 で作業ツリーごと消え、変更も untracked ファイルも残らなかった。
  /// 別の worktree の検査から作った確認をそのまま通すと、**A の未commit変更がユーザーに一度も
  /// 警告を見せないまま消える**。
  @Test(
    "別の worktree について作られた確認では削除を計画できない",
    arguments: [
      WorktreeCloseChoice.terminateSession(.removeWorktree(.keepBranch)),
      .terminateSession(.removeWorktree(.deleteBranch)),
    ])
  func planRejectsConfirmationMadeForAnotherWorktree(choice: WorktreeCloseChoice) throws {
    let target = try worktree("/repo/.git/worktrees/feature-a")
    let other = try worktree("/repo/.git/worktrees/feature-b")
    let confirmationForOther = confirmation(
      for: other, uncommitted: .present, merge: .merged,
      continuation: .forcingAcknowledgedWarnings)

    #expect(
      throws: WorktreeClosePlanError.confirmationIsForAnotherWorktree(
        confirmation: other.identity, target: target.identity)
    ) {
      try planWorktreeClose(
        worktree: target, choice: choice, confirmation: confirmationForOther)
    }
  }

  /// §3.4 が検査と確認を課すのは選択肢3・4 だけである。1・2 は確認を要求しないので、渡された
  /// 確認も読まない —— 読まない値の対象を問うと、削除を伴わない Close が確認の取り違えで
  /// 失敗することになる。
  @Test(
    "削除を伴わない選択肢は確認を読まないので対象の一致も問わない",
    arguments: [WorktreeCloseChoice.hideFromUI, .terminateSession(.keepWorktree)])
  func planIgnoresTheConfirmationForChoicesThatDoNotRemove(choice: WorktreeCloseChoice) throws {
    let target = try worktree("/repo/.git/worktrees/feature-a")
    let other = try worktree("/repo/.git/worktrees/feature-b")

    let plan = try planWorktreeClose(
      worktree: target, choice: choice, confirmation: confirmation(for: other))

    #expect(plan.worktree == target.identity)
  }

  @Test("対象が違えば、同じ step 列でも別の計画になる")
  func plansForDifferentWorktreesAreNotEqual() throws {
    func plan(_ target: DetectedWorktree) throws -> WorktreeClosePlan {
      try planWorktreeClose(
        worktree: target, choice: .terminateSession(.keepWorktree), confirmation: nil)
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
    let target = try worktree("/repo/.git/worktrees/feature-b", branch: "feature-b")

    let plan = try planWorktreeClose(
      worktree: target, choice: .terminateSession(.removeWorktree(.deleteBranch)),
      confirmation: confirmation(for: target, merge: .merged))

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
    let target = try worktree("/repo/.git", branch: "main", isProjectRoot: true)

    #expect(throws: WorktreeClosePlanError.projectRootIsNotClosable) {
      try planWorktreeClose(
        worktree: target, choice: choice,
        confirmation: confirmation(for: target, merge: .merged))
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

  private func confirmation(
    for worktree: DetectedWorktree,
    uncommitted: UncommittedChangesStatus = .absent,
    ignored: IgnoredFilesStatus = .absent,
    merge: BranchMergeStatus = .unmerged,
    defaultBranch: DefaultBranchResolution = .originHead(branch: "main"),
    continuation: WorktreeRemovalConfirmation.Continuation = .withoutForce
  ) -> WorktreeRemovalConfirmation {
    WorktreeRemovalConfirmation(
      worktree: worktree.identity,
      inspection: WorktreeCloseInspection(
        uncommittedChanges: uncommitted, ignoredFiles: ignored, unpushedCommits: .absent,
        branchMerge: merge),
      defaultBranch: defaultBranch, continuation: continuation)
  }
}
