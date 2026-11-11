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

  public func isOnFirstParentChain(
    tip: CommitObjectID, destination: CommitObjectID
  ) async -> Bool? {
    guard tip != destination else { return true }
    guard let tipRevision = GitRevision(tip.rawValue),
      let destinationRevision = GitRevision(destination.rawValue)
    else { return nil }
    let output: String
    do {
      output = try await judge.runner.run(
        .firstParentChain(from: destinationRevision, excluding: tipRevision)
      ).stdout
    } catch {
      return nil
    }
    switch Self.isFirstParent(tip, ofLastLineIn: output) {
    case .onChain(let result): return result
    case .parentless:
      do {
        let shallow = try await judge.runner.run(.isShallowRepository()).stdout
        return shallow.trimmingCharacters(in: .whitespacesAndNewlines) == "false" ? false : nil
      } catch {
        return nil
      }
    case nil: return nil
    }
  }

  private enum FirstParentResult {
    case onChain(Bool)
    case parentless
  }

  /// tip が first-parent の列の上にあれば、除外側の tip の子で walk は止まる。そのため最後が親の無い
  /// 行なら、shallow でないと確かめられた場合に限り、tip は列の上に無い (`false`) と確定できる。
  /// 親の無い行は、無関係な履歴を `--allow-unrelated-histories` で merge した場合や、commit 日時の
  /// ずれで走査が root まで行き過ぎた場合に現れる。shallow の境界も親の無い行に見えるので、shallow
  /// なら判定不能にする。`DiffSnapshotBuilder` が共通祖先の不在を断定する前に shallow でないことを
  /// 求めるのと同じ向き (Issue #912)。
  private static func isFirstParent(
    _ tip: CommitObjectID, ofLastLineIn output: String
  ) -> FirstParentResult? {
    guard let line = output.split(separator: "\n").last else { return nil }
    let fields = line.split(separator: " ", omittingEmptySubsequences: false)
      .map { CommitObjectID(String($0)) }
    guard fields.allSatisfy({ $0 != nil }) else { return nil }
    guard fields.count >= 2 else { return .parentless }
    return .onChain(fields[1] == tip)
  }

  private func resolve(_ revision: GitRevision) async -> CommitObjectID? {
    switch await judge.resolveCommit(revision) {
    case .resolved(let tip): tip
    case .failed: nil
    }
  }
}
