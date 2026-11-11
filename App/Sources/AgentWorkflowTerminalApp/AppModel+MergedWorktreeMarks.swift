import Adapters
import Foundation
import TerminalCore

extension AppModel {
  /// git を起動できない Project では `nil` で、印は出ない。
  static func makeMergedMarkRefresher(
    projectDirectory: URL, mergeCache: GitBranchMergeCache, queue: BranchMergeJudgementQueue
  ) -> (refresher: MergedWorktreeMarkRefresher, changes: AsyncStream<Set<WorktreeIdentity>>)? {
    guard
      let probe = try? GitBranchMergeProbe(
        repositoryDirectory: projectDirectory, processRunner: FoundationProcessRunner(),
        mergeCache: mergeCache)
    else { return nil }
    // `onChange` は refresher の actor から同期で呼ばれる。呼ぶたびに Task を作ると実行順が
    // 入れ替わって古い集合が最後に残りうるので、stream で順序を保って MainActor の1本が読む。
    let (changes, continuation) = AsyncStream.makeStream(
      of: Set<WorktreeIdentity>.self, bufferingPolicy: .unbounded)
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: queue, onChange: { continuation.yield($0) })
    return (refresher, changes)
  }

  func startConsumingMergedMarks(_ changes: AsyncStream<Set<WorktreeIdentity>>) {
    mergedMarkConsumer = Task { @MainActor [weak self] in
      for await marked in changes {
        guard let self else { return }
        applyMergedWorktrees(marked)
      }
    }
  }

  func stopMergedMarks() {
    mergedMarkConsumer?.cancel()
    mergedMarkConsumer = nil
    guard let refresher = mergedMarkRefresher else { return }
    Task { await refresher.stop() }
  }

  /// actor への投函だけで、周の終わりは待たない。
  func requestMergedMarks() async {
    await mergedMarkRefresher?.request(
      targets: sessionWorktrees.map(\.detected), projectRootBranch: projectRoot?.branch)
  }
}
