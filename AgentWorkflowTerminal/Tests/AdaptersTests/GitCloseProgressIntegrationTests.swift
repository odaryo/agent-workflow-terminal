import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 実 git に対して、§3.4 の 2026-10-08 の3つの確定を固定する。
///
/// - 選択肢4は `git branch -D` で消す (Issue #359)。upstream が削除されて `fetch --prune` された
///   後の squash merge 済み branch —— PR のマージ後に Close する最も普通の状況 —— で確かめる。
/// - 作業途中の worktree は Close を拒否する (Issue #355)。
/// - 拒否は計画時と実行直前の2回判定する (Issue #354)。
///
/// fixture では固定できない。途中状態の印がどこに置かれるか (pseudo ref か、管理ディレクトリの
/// ファイルか) と、そのとき HEAD が branch を指したままかは、実際にその操作を途中で止めないと
/// 再現できない。tmux は stub で置き換え、中止したときに1回も呼ばれていないことで
/// 「session が残る」を確かめる。
///
/// `.serialized` は `GitSquashMergeCloseIntegrationTests` と同じ理由 (実 git のプロセス数で
/// wall-clock の閾値を持つテストを押し出す)。
@Suite("§3.4 実 git の作業途中・実行直前の読み直し・branch -D", .serialized)
struct GitCloseProgressIntegrationTests {
  private static let everyChoice: [WorktreeCloseChoice] = [
    .hideFromUI, .terminateSession(.keepWorktree),
    .terminateSession(.removeWorktree(.keepBranch)),
    .terminateSession(.removeWorktree(.deleteBranch)),
  ]

  @Test("squash merge 済みで upstream が gone の branch を、選択肢4が削除できる (Issue #359)")
  func deletesSquashMergedBranchWhoseUpstreamIsGone() async throws {
    try await withGitRepository { repository in
      try await repository.prepareSquashMergedBranchWithGoneUpstream("topic")

      // 前提の対照: upstream の設定は残り、追跡 ref は消えている (`[origin/topic: gone]`)。
      // この状態の squash merge 済み branch に `branch -d` は rc=1 で拒否する (git 2.50.1 実測)。
      #expect(try await repository.gitExitCode(["config", "branch.topic.remote"]).exitCode == 0)
      #expect(try await repository.refExists("refs/remotes/origin/topic") == false)

      let target = try await repository.detected(branch: "topic")
      let inspection = await GitCloseSafetyInspector(
        runner: try repository.runner(globalConfig: "", in: "topic"), target: target
      ).inspect(projectRootBranch: "main")
      #expect(inspection.failures.isEmpty)
      // 確認の層が「git は未マージと見なしているが squash merge と判定した」を出せる情報。
      let tip = try await repository.branchTip("topic")
      #expect(inspection.report.inspection.branchMerge == .merged(.squash, tip: tip))

      let plan = try planWorktreeClose(
        worktree: target, progress: try await repository.progressReport(for: target),
        choice: .terminateSession(.removeWorktree(.deleteBranch)),
        confirmation: .init(report: inspection.report, continuation: .withoutForce))
      let harness = try repository.closeHarness(for: target)

      let execution = try await harness.executor.execute(plan)

      #expect(execution.outcome?.failure == nil)
      #expect(execution.outcome?.completed == plan.steps)
      #expect(try await repository.refExists("refs/heads/topic") == false)
      #expect(!FileManager.default.fileExists(atPath: target.worktreePath))
    }
  }

  @Test(
    "作業途中の worktree は、HEAD が branch を指していてもどの選択肢でも Close できない",
    arguments: InProgressScenario.allCases)
  func rejectsCloseForOperationInProgress(scenario: InProgressScenario) async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("wt")
      try await scenario.interrupt(in: "wt", of: repository)

      let target = try await repository.detected(branch: "wt")
      // 対照: detached の条件では捕まらない (HEAD は branch を指したまま)。
      #expect(target.branch == "wt")
      let progress = try await repository.progressReport(for: target)
      #expect(progress.progress == .observed([scenario.operation]))

      for choice in Self.everyChoice {
        #expect(throws: WorktreeClosePlanError.operationInProgress([scenario.operation])) {
          try planWorktreeClose(
            worktree: target, progress: progress, choice: choice, confirmation: nil)
        }
      }
    }
  }

  /// 停止中の rebase は HEAD を detach する (git 2.50.1 実測) ので、計画は detached として
  /// 拒否する。途中状態の観測が rebase を見ていることは別に確かめる —— HEAD を branch に
  /// 戻した rebase (`rebase --apply` でも `git am` でも) が素通りしないため。
  @Test("rebase の途中の worktree は detached として拒否し、観測は rebase を返す")
  func rejectsCloseForInterruptedRebase() async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("wt", commits: ["t.txt"])
      #expect(
        try await repository.gitExitCode(["rebase", "--exec", "false", "main"], in: "wt").exitCode
          != 0)

      let target = try #require(
        try await repository.detector().scan().detected.first { !$0.isProjectRoot })
      #expect(target.branch == nil)
      let progress = try await repository.progressReport(for: target)
      #expect(progress.progress == .observed([.rebase]))
      for choice in Self.everyChoice {
        #expect(throws: WorktreeClosePlanError.detachedHeadIsNotClosable) {
          try planWorktreeClose(
            worktree: target, progress: progress, choice: choice, confirmation: nil)
        }
      }
    }
  }

  @Test(
    "計画の後に worktree が変わったら、実行は何もせず中止し session も worktree も branch も残る",
    arguments: PostPlanChange.allCases)
  func abandonsWhenTheWorktreeChangesAfterPlanning(change: PostPlanChange) async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("topic")
      let target = try await repository.detected(branch: "topic")
      let plan = try await repository.branchDeletionPlan(for: target)
      let tip = try await repository.branchTip("topic")
      #expect(plan.steps.last == .deleteBranch(name: "topic", tip: tip))

      try await change.apply(to: "topic", of: repository)
      let harness = try repository.closeHarness(for: target)

      let execution = try await harness.executor.execute(plan)

      #expect(execution.refusal == change.expectedRefusal)
      #expect(await harness.tmux.invocations.isEmpty)
      #expect(FileManager.default.fileExists(atPath: target.worktreePath))
      #expect(
        try await repository.detector().scan().detected.contains { $0.identity == target.identity })
      #expect(try await repository.refExists("refs/heads/topic"))
    }
  }

  /// `branch -D` は未マージの commit も消す。計画の後に Agent が commit を積んだ branch を、
  /// マージ済みという古い判定のまま消さない (Issue #359)。
  @Test("計画の後に branch へ commit が積まれたら、実行は何もせず中止し commit も branch も残る")
  func abandonsWhenTheBranchTipMovesAfterPlanning() async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("topic")
      let target = try await repository.detected(branch: "topic")
      let plan = try await repository.branchDeletionPlan(for: target)
      let plannedTip = try await repository.branchTip("topic")

      try await repository.commit(file: "late.txt", contents: "late", in: "topic")
      let movedTip = try await repository.branchTip("topic")
      let harness = try repository.closeHarness(for: target)

      let execution = try await harness.executor.execute(plan)

      #expect(execution.refusal == .branchTipMoved(planned: plannedTip, current: movedTip))
      #expect(await harness.tmux.invocations.isEmpty)
      #expect(FileManager.default.fileExists(atPath: target.worktreePath))
      #expect(try await repository.branchTip("topic") == movedTip)
    }
  }

  /// session を終了するまで Agent は動いている。冒頭の照合の後に積まれた commit を、`-D` の直前の
  /// 読み直しで止める (Issue #359)。worktree はその時点でもう無いので、commit は
  /// `commit-tree` + `update-ref` で branch へ直接積む —— `worktree remove` の直後、`-D` の前に。
  @Test("worktree 削除の後に branch へ commit が積まれたら、-D を撃たず branch と commit が残る")
  func keepsTheBranchWhenTheTipMovesAfterWorktreeRemoval() async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("topic")
      let target = try await repository.detected(branch: "topic")
      let plan = try await repository.branchDeletionPlan(for: target)
      let plannedTip = try await repository.branchTip("topic")
      let committer = try repository.runner(
        globalConfig: "[user]\n\tname = awt\n\temail = awt@example.invalid\n")
      let lateCommit = LateCommit()
      let harness = try repository.closeHarness(
        for: target,
        processRunner: AfterWorktreeRemovalRunner {
          let tree = try await committer.run(
            GitReadCommand(arguments: ["rev-parse", "\(plannedTip.rawValue)^{tree}"])
          ).stdout.trimmingCharacters(in: .newlines)
          let late = try await committer.run(
            GitReadCommand(arguments: [
              "commit-tree", tree, "-p", plannedTip.rawValue, "-m", "late",
            ])
          ).stdout.trimmingCharacters(in: .newlines)
          try await repository.git(["update-ref", "refs/heads/topic", late, plannedTip.rawValue])
          await lateCommit.set(late)
        })

      let execution = try await harness.executor.execute(plan)

      let lateHex = try #require(await lateCommit.value)
      let late = try #require(CommitObjectID(lateHex))
      let outcome = try #require(execution.outcome)
      #expect(outcome.completed == [.terminateSession, .removeWorktree(force: false)])
      #expect(outcome.failure?.reason == .branchTipMoved(planned: plannedTip, current: late))
      #expect(!FileManager.default.fileExists(atPath: target.worktreePath))
      #expect(try await repository.branchTip("topic") == late)
    }
  }

  /// git 2.50.1 実測: 衝突中の `MERGE_HEAD` を空にすると `rev-parse --verify` は rc=1 (= 無い) を
  /// 返すが、`git status` は `You have unmerged paths.` のままだった。
  @Test("空にした MERGE_HEAD でも、merge の途中として拒否する")
  func rejectsCloseWithAnEmptiedMergeHead() async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("wt")
      try await InProgressScenario.conflictedMerge.interrupt(in: "wt", of: repository)
      let target = try await repository.detected(branch: "wt")
      let mergeHead = target.identity.rawValue + "/MERGE_HEAD"
      try Data().write(to: URL(fileURLWithPath: mergeHead))
      // 前提の対照: git はもう MERGE_HEAD を ref として読まない。
      #expect(
        try await repository.gitExitCode(
          ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: "wt"
        )
        .exitCode == 1)

      let progress = try await repository.progressReport(for: target)

      #expect(progress.progress == .observed([.merge]))
    }
  }

  /// 空の `CHERRY_PICK_HEAD` を git は途中と扱わず、git のどのコマンドでも消せない (git 2.50.1
  /// 実測: `cherry-pick --abort` は rc=128、`reset --hard` の後も残る)。拒否し続けると「完了または
  /// 中止を」という案内が実行できないので、git と同じく途中とみなさない。
  @Test("git が途中と扱わない空の CHERRY_PICK_HEAD では、作業途中として拒否しない")
  func doesNotRejectCloseForAnEmptiedCherryPickHead() async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("wt")
      try await InProgressScenario.conflictedCherryPick.interrupt(in: "wt", of: repository)
      let target = try await repository.detected(branch: "wt")
      try Data().write(to: URL(fileURLWithPath: target.identity.rawValue + "/CHERRY_PICK_HEAD"))
      // 前提の対照: git は途中と扱わず、中止もできない。ファイルは reset の後も残る。
      #expect(
        try await repository.gitExitCode(["cherry-pick", "--abort"], in: "wt").exitCode == 128)
      try await repository.git(["reset", "-q", "--hard"], in: "wt")
      #expect(
        FileManager.default.fileExists(atPath: target.identity.rawValue + "/CHERRY_PICK_HEAD"))

      let progress = try await repository.progressReport(for: target)

      #expect(progress.progress == .observed([]))
    }
  }

  /// 保存から復元した `DetectedWorktree` は、観測できなかった間に detached になっていても
  /// 保存時の branch を持つ (`restoreWorktreeInventory` の leftover)。計画段階の detached の
  /// 判定はこの値を見るので素通りし、止めるのは実行直前の読み直しである。
  @Test("保存から復元した陳腐化した branch の計画でも、実行直前の読み直しで止まる (Issue #354)")
  func abandonsPlanBuiltFromRestoredStaleBranch() async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("topic")
      let scanned = try await repository.detector().scan().detected
      let saved = PersistedWorktreeInventory(
        restoreWorktreeInventory(detected: scanned, saved: nil).inventory)

      try await repository.git(["checkout", "-q", "--detach"], in: "topic")
      let restored = restoreWorktreeInventory(
        detected: scanned.filter(\.isProjectRoot), saved: saved)
      let stale = try #require(restored.inventory.taskWorktrees.first?.detected)
      #expect(stale.branch == "topic")

      let plan = try await repository.branchDeletionPlan(for: stale)
      let harness = try repository.closeHarness(for: stale)

      let execution = try await harness.executor.execute(plan)

      #expect(execution.refusal == .detachedHead)
      #expect(await harness.tmux.invocations.isEmpty)
      #expect(FileManager.default.fileExists(atPath: stale.worktreePath))
      #expect(try await repository.refExists("refs/heads/topic"))
    }
  }
}
