import Foundation
import TerminalCore

/// Overview のマージ済みの印 (Issue #879) のための判定。`gh` も `fetch` も呼ばず、ローカルの ref
/// だけを読む。判定は Close と同じ `GitBranchMergeJudge` で行う。
public struct GitBranchMergeProbe: BranchMergeProbing {
  private let judge: GitBranchMergeJudge

  /// `repositoryDirectory` は Project Root の作業ツリー (ref は全 worktree で共有される)。
  public init(
    repositoryDirectory: URL, processRunner: any ProcessRunning,
    mergeCache: GitBranchMergeCache,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    // Close と同じく replace ref と grafts を無効にする (設計書 §3.4、Issue #384)。
    let runner = try GitRunner(
      repositoryDirectory: repositoryDirectory, processRunner: processRunner,
      executableCandidates: executableCandidates, ignoresHistoryRewrites: true)
    self.init(runner: runner, mergeCache: mergeCache)
  }

  init(
    runner: GitRunner, mergeCache: GitBranchMergeCache,
    squashScanCommitLimit: Int = GitCloseSafetyInspector.defaultSquashScanCommitLimit
  ) {
    self.judge = GitBranchMergeJudge(
      runner: runner, squashScanCommitLimit: squashScanCommitLimit, mergeCache: mergeCache)
  }

  public func branchTip(_ branch: String) async -> CommitObjectID? {
    guard let revision = localBranchRevision(branch) else { return nil }
    return await resolve(revision)
  }

  public func defaultBranchTip(projectRootBranch: String?) async -> CommitObjectID? {
    let defaultBranch = await judge.resolveDefaultBranch(projectRootBranch: projectRootBranch)
    guard let revision = defaultBranch.revision.flatMap({ GitRevision($0) }) else { return nil }
    return await resolve(revision)
  }

  public func mergeStatus(
    tip: CommitObjectID, destination: CommitObjectID
  ) async -> BranchMergeStatus {
    await judge.judge(tip: tip, destination: destination).status
  }

  private func resolve(_ revision: GitRevision) async -> CommitObjectID? {
    switch await judge.resolveCommit(revision) {
    case .resolved(let tip): tip
    case .failed: nil
    }
  }
}
