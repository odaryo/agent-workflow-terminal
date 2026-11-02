import TerminalCore

extension GitWorktreeDetector {
  /// `describeUnreachable` と同じ finder を使い、注入した finder と判定がずれないようにする (Issue #531)。
  static func resolveSharedIdentities(
    detected: [DetectedWorktree],
    failures: [GitWorktreeEntryFailure],
    commonDirectory: WorktreeIdentity,
    findAdministrativeDirectory: @Sendable (String, WorktreeIdentity) -> WorktreeIdentity?
  ) -> GitWorktreeScanResult {
    let groups = Dictionary(
      grouping: detected.indices.filter { !detected[$0].isProjectRoot },
      by: { detected[$0].identity }
    )
    var rejected: Set<Int> = []
    for (identity, indices) in groups where indices.count > 1 {
      let genuine = indices.filter {
        findAdministrativeDirectory(
          detected[$0].worktreePath, commonDirectory
        ) == identity
      }
      if genuine.count == 1, let retained = genuine.first {
        rejected.formUnion(indices.filter { $0 != retained })
      } else {
        rejected.formUnion(indices)
      }
    }

    var retained: [DetectedWorktree] = []
    var failures = failures
    for (index, worktree) in detected.enumerated() {
      if rejected.contains(index) {
        failures.append(
          GitWorktreeEntryFailure(
            worktreePath: worktree.worktreePath,
            reason: .sharedIdentity(gitDirectory: worktree.identity.rawValue)
          ))
      } else {
        retained.append(worktree)
      }
    }
    return GitWorktreeScanResult(detected: retained, failures: failures)
  }
}
