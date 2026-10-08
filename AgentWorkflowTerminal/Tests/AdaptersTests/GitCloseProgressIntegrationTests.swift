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

/// 計画を立てた後、実行までの間に worktree に起きること (Issue #354 の経路 a)。
enum PostPlanChange: CaseIterable, Sendable {
  case detach
  case switchBranch
  case conflictedMerge

  var expectedRefusal: WorktreeClosePreflightRefusal {
    switch self {
    case .detach: .detachedHead
    case .switchBranch: .branchChanged(planned: "topic", current: "other")
    case .conflictedMerge: .operationInProgress([.merge])
    }
  }

  func apply(to worktree: String, of repository: GitTestRepository) async throws {
    switch self {
    case .detach:
      try await repository.git(["checkout", "-q", "--detach"], in: worktree)
    case .switchBranch:
      try await repository.git(["checkout", "-q", "-b", "other"], in: worktree)
    case .conflictedMerge:
      try await repository.commitConflictingSide()
      try await repository.commit(file: "f.txt", contents: "ours", in: worktree)
      #expect(try await repository.gitExitCode(["merge", "side"], in: worktree).exitCode == 1)
    }
  }
}

/// 途中で止めた操作と、そのとき観測されるべき種類 (git 2.50.1 実測。どれも HEAD は branch を
/// 指したまま)。
enum InProgressScenario: CaseIterable, Sendable {
  case conflictedMerge
  case conflictedCherryPick
  case conflictedRevert
  case bisect
  /// 連続 cherry-pick の1件目の衝突を素の `git commit` で解決した後。
  case resolvedSequence
  case conflictedMailboxApply

  var operation: WorktreeInProgressOperation {
    switch self {
    case .conflictedMerge: .merge
    case .conflictedCherryPick: .cherryPick
    case .conflictedRevert: .revert
    case .bisect: .bisect
    case .resolvedSequence: .sequence
    case .conflictedMailboxApply: .mailboxApply
    }
  }

  func interrupt(in worktree: String, of repository: GitTestRepository) async throws {
    switch self {
    case .conflictedMerge:
      try await repository.commitConflictingSide()
      try await repository.commit(file: "f.txt", contents: "ours", in: worktree)
      try await repository.expectFailure(["merge", "side"], in: worktree)
    case .conflictedCherryPick:
      try await repository.commitConflictingSide()
      try await repository.commit(file: "f.txt", contents: "ours", in: worktree)
      try await repository.expectFailure(["cherry-pick", "side~1"], in: worktree)
    case .conflictedRevert:
      try await repository.commit(file: "f.txt", contents: "first", in: worktree)
      try await repository.commit(file: "f.txt", contents: "second", in: worktree)
      try await repository.expectFailure(["revert", "--no-edit", "HEAD~1"], in: worktree)
    case .bisect:
      // 範囲を渡すと中間の commit を checkout して HEAD が detach する。引数なしの `start` は
      // checkout せず、HEAD は branch を指したまま `BISECT_LOG` だけが置かれる。
      try await repository.git(["bisect", "start"], in: worktree)
    case .resolvedSequence:
      try await repository.commitConflictingSide()
      try await repository.commit(file: "f.txt", contents: "ours", in: worktree)
      try await repository.expectFailure(["cherry-pick", "side~1", "side"], in: worktree)
      try await repository.commit(file: "f.txt", contents: "resolved", in: worktree)
    case .conflictedMailboxApply:
      try await repository.commitConflictingSide()
      try await repository.commit(file: "f.txt", contents: "ours", in: worktree)
      let patches = repository.root.appending(path: "patches")
      try await repository.git(["format-patch", "-q", "-1", "side~1", "-o", patches.path])
      let patch = try #require(
        try FileManager.default.contentsOfDirectory(atPath: patches.path).first)
      try await repository.expectFailure(
        ["am", patches.appending(path: patch).path], in: worktree)
    }
  }
}

extension GitTestRepository {
  /// 既定 branch から `-b` で作る。`commits` の各要素は1 commit で書くファイル名。
  func addWorktree(_ branch: String, commits: [String] = []) async throws {
    try await git(["worktree", "add", "-q", "-b", branch, "../\(branch)"])
    for name in commits {
      try await commit(file: name, contents: name, in: branch)
    }
  }

  func commit(file: String, contents: String, in worktree: String?) async throws {
    let directory = worktree.map { root.appending(path: $0) } ?? mainWorktree
    try (contents + "\n").write(
      to: directory.appending(path: file), atomically: true, encoding: .utf8)
    try await git(["add", "-A"], in: worktree)
    try await git(["commit", "-q", "-m", "\(file): \(contents)"], in: worktree)
  }

  /// 既定 branch から分かれた `side` に、`f.txt` を書く commit と、無関係な commit を積む。
  /// `side~1` が衝突する側、`side` が衝突しない側になる。
  func commitConflictingSide() async throws {
    try await git(["branch", "side", "main"])
    try await git(["worktree", "add", "-q", "../side", "side"])
    try await commit(file: "f.txt", contents: "theirs", in: "side")
    try await commit(file: "s.txt", contents: "unrelated", in: "side")
  }

  func expectFailure(_ arguments: [String], in worktree: String) async throws {
    let result = try await gitExitCode(arguments, in: worktree)
    #expect(result.exitCode != 0, "\(arguments) は途中で止まるはずだった: \(result.stderr)")
  }

  /// 製品が使う `rev-parse` とは別の経路 (`log --format=%H`) で読む。
  func branchTip(_ branch: String) async throws -> CommitObjectID {
    let output = try await runner(globalConfig: "").run(
      GitReadCommand(arguments: ["log", "-1", "--format=%H", "refs/heads/\(branch)"])
    ).stdout
    return try #require(CommitObjectID(output.trimmingCharacters(in: .newlines)))
  }

  func refExists(_ reference: String) async throws -> Bool {
    try await gitExitCode(["rev-parse", "--verify", "--quiet", reference]).exitCode == 0
  }

  func detected(branch: String) async throws -> DetectedWorktree {
    try #require(try await detector().scan().detected.first { $0.branch == branch })
  }

  /// bare origin へ push した branch を squash merge し、origin 側の branch を消して
  /// `fetch --prune` する —— PR を squash merge して GitHub が branch を消した後の手元と同じ形。
  func prepareSquashMergedBranchWithGoneUpstream(_ branch: String) async throws {
    let origin = root.appending(path: "origin.git")
    try await git(["init", "-q", "--bare", "-b", "main", origin.path])
    try await git(["remote", "add", "origin", origin.path])
    try await git(["push", "-q", "-u", "origin", "main"])
    try await addWorktree(branch, commits: ["a.txt", "b.txt", "c.txt"])
    try await git(["push", "-q", "-u", "origin", branch], in: branch)
    try await git(["merge", "-q", "--squash", branch])
    try await git(["commit", "-q", "-m", "squash \(branch)"])
    try await git(["push", "-q", "origin", "main"])
    try await git(["push", "-q", "origin", "--delete", branch])
    try await git(["fetch", "-q", "--prune", "origin"])
  }

  func progressReport(for target: DetectedWorktree) async throws -> WorktreeOperationProgressReport
  {
    let result = await GitWorktreeProgressInspector(
      target: target, runner: try runner(globalConfig: "", in: try relativeName(target.identity)),
      fileExists: { FileManager.default.fileExists(atPath: $0) }
    ).inspect()
    #expect(result.failure == nil)
    return result.report
  }

  /// 既定 branch から分かれたばかりの branch は ancestor 判定でマージ済みなので、選択肢4の
  /// 計画が立つ。消える操作を最も多く含む計画で中止を確かめるために使う。
  func branchDeletionPlan(for target: DetectedWorktree) async throws -> WorktreeClosePlan {
    let inspection = await GitCloseSafetyInspector(
      runner: try runner(globalConfig: "", in: target.branch), target: target
    ).inspect(projectRootBranch: "main")
    let tip = try await branchTip(try #require(target.branch))
    #expect(inspection.report.inspection.branchMerge == .merged(.ancestor, tip: tip))
    return try planWorktreeClose(
      worktree: target, progress: try await progressReport(for: target),
      choice: .terminateSession(.removeWorktree(.deleteBranch)),
      confirmation: .init(report: inspection.report, continuation: .forcingAcknowledgedWarnings))
  }

  /// 実 git と tmux の stub で動く実行層。git は偽の `HOME` (空の `.gitconfig`) で起動する ——
  /// `runner(globalConfig:)` と同じく、実行環境の `~/.gitconfig` を読ませないため。
  func closeHarness(
    for target: DetectedWorktree, processRunner: any ProcessRunning = FoundationProcessRunner()
  ) throws -> RealGitCloseHarness {
    let home = root.appending(path: "home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try "".write(to: home.appending(path: ".gitconfig"), atomically: true, encoding: .utf8)
    let tmux = TmuxSessionRunnerStub(result: stubSuccess())
    let executor = try WorktreeCloseExecutor(
      repositoryDirectory: mainWorktree, worktree: target,
      sessionOperations: TmuxSessionOperations(
        runner: try TmuxRunner(
          socketName: "awt-test", processRunner: tmux,
          executableCandidates: [URL(fileURLWithPath: "/test/bin/tmux")], parentEnvironment: [:],
          isExecutableFile: { _ in true })),
      processRunner: processRunner,
      executableCandidates: GitRunner.defaultExecutableCandidates,
      parentEnvironment: [
        "HOME": home.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
      ],
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) },
      fileExists: { FileManager.default.fileExists(atPath: $0) })
    return RealGitCloseHarness(tmux: tmux, executor: executor)
  }

  private func relativeName(_ identity: WorktreeIdentity) throws -> String {
    let prefix = root.path + "/"
    try #require(identity.rawValue.hasPrefix(prefix))
    return String(identity.rawValue.dropFirst(prefix.count))
  }
}

struct RealGitCloseHarness {
  let tmux: TmuxSessionRunnerStub
  let executor: WorktreeCloseExecutor
}

/// `worktree remove` を撃った直後に1回だけ `afterRemoval` を走らせる。失敗はテストの issue にする。
struct AfterWorktreeRemovalRunner: ProcessRunning {
  let afterRemoval: @Sendable () async throws -> Void
  private let base = FoundationProcessRunner()

  init(afterRemoval: @escaping @Sendable () async throws -> Void) {
    self.afterRemoval = afterRemoval
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    let result = try await base.run(
      executableURL: executableURL, arguments: arguments, environment: environment,
      timeout: timeout, outputLimit: outputLimit)
    if arguments.contains("worktree"), arguments.contains("remove") {
      do {
        try await afterRemoval()
      } catch {
        Issue.record("worktree remove の後の commit に失敗した: \(error)")
      }
    }
    return result
  }
}

actor LateCommit {
  private(set) var value: String?

  func set(_ value: String) {
    self.value = value
  }
}
