import TerminalCore

extension GitWorktreeDetector {
  private static let branchRefPrefix = "refs/heads/"

  /// - Important: Issue #401 の実測 (2026-11-12、git 2.54.0 Apple Git-157、
  ///   `GIT_CONFIG_GLOBAL=/dev/null`) では、lock していない linked worktree が非 prunable で
  ///   あることが保証するのは、管理ディレクトリの `gitdir` に記録された `<P>/.git` を
  ///   `lstat` できたことだけである。`.git` の中身や admin 側の `HEAD` / `commondir`、
  ///   指している repository の正しさは保証しない。locked は到達不能になっても prunable が
  ///   付かないので再利用しない。同じパスで作り直された worktree に古い ID を配らない
  ///   よう、Project Root 側の common dir で管理ディレクトリを照合する。
  ///   作業ツリー側の同期 FS 判定を先に撃つと応答しないマウントで打ち切れなくなるため、再利用時も
  ///   呼ばない (`isReachableWorkingTree` の非 prunable に対する制約)。
  /// - Important: 再利用中は、`.git` の中身や admin 側の破損、兄弟の admin や別 repository を
  ///   指す状態など、prunable が付かず管理ディレクトリの照合も通る壊れ方を検出できない。
  ///   hostctl の `worktree open` のように Active 化の直前にスキャンを要求できる経路では、
  ///   呼び出し側は `reusableObservations` に空を渡すこと。人の Active 化は直前の使い回した
  ///   観測で判定するため、これらの壊れ方は Active 化後の最初のスキャンまで残る。
  ///   `.git` や admin を手で書き換えた人工的な状態でしか起きないため、この窓は受け入れる
  ///   (Issue #401)。
  static func reusedObservation(
    _ entry: GitWorktreeEntry,
    isMainWorktree: Bool,
    commonDirectory: WorktreeIdentity,
    observations: [DetectedWorktree],
    findAdministrativeDirectory: (String, WorktreeIdentity) -> WorktreeIdentity?
  ) -> DetectedWorktree? {
    guard !isMainWorktree, entry.prunableReason == nil, entry.lockedReason == nil,
      let reusable = observations.first(where: {
        $0.worktreePath == entry.path && $0.observation == .reachable && !$0.isProjectRoot
      }),
      findAdministrativeDirectory(entry.path, commonDirectory) == reusable.identity
    else { return nil }
    return DetectedWorktree(
      identity: reusable.identity,
      worktreePath: entry.path,
      branch: entry.branch.map(Self.shortBranchName),
      isProjectRoot: false,
      isReachable: true
    )
  }

  /// `refs/heads/` が付かない値は加工せずに返す。branch 名は `feat/a` のように `/` を含み得るので、
  /// 最後の要素を取る短縮はできない。
  static func shortBranchName(_ reference: String) -> String {
    guard reference.hasPrefix(branchRefPrefix) else { return reference }
    return String(reference.dropFirst(branchRefPrefix.count))
  }
}
