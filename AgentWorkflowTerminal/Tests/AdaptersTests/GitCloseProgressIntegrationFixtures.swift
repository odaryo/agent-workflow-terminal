import Foundation
import TerminalCore
import Testing

@testable import Adapters

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
