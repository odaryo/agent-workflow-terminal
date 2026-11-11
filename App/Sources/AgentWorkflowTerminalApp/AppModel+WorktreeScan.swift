import Adapters
import Foundation
import TerminalCore

extension AppModel {
  /// hostctl の要求で回す回は、直後に Inactive の worktree を Active 化し得るので使い回さない。
  /// 使い回している間は、別 repository への置き換えなど `rev-parse` だけが気づく壊れ方を
  /// 検出できないため (Issue #401)。
  func reusableObservations(isRequestedScan: Bool) -> [DetectedWorktree] {
    guard !isRequestedScan else { return [] }
    return worktrees.filter { $0.activation == .inactive }.map(\.detected)
  }

  func scan(
    with detector: GitWorktreeDetector,
    knownIdentities: [WorktreeIdentity] = [],
    reusableObservations: [DetectedWorktree] = []
  ) async -> Result<GitWorktreeScanResult, GitWorktreeScanError> {
    do {
      let scan = try await detector.scan(
        knownIdentities: knownIdentities, reusableObservations: reusableObservations)
      // 失敗した entry は `detected` に載らないため、呼び出し側が `unobserved` として渡す。
      // 原因の原文はバナーに載せきれないので、ここに残す。
      for failure in scan.failures {
        NSLog("[app] worktree の検出に失敗: \(String(describing: failure))")
      }
      if let listingFailure = scan.listingFailure {
        NSLog("[app] worktree の一覧取得に失敗: \(String(describing: listingFailure))")
      }
      return .success(scan)
    } catch {
      return .failure(error)
    }
  }
}
