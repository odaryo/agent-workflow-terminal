import TerminalCore

extension GitWorktreeDetector {
  private static let branchRefPrefix = "refs/heads/"

  /// - Important: Issue #401 の実測 (2026-11-12、git 2.54.0 Apple Git-157、
  ///   `GIT_CONFIG_GLOBAL=/dev/null`) では、lock していない linked worktree は、作業ツリーの
  ///   削除、`chmod 000`、`.git` ファイルの削除、親ディレクトリの `chmod 000` のいずれでも
  ///   `worktree list` に `prunable gitdir file points to non-existent location` が付いた。
  ///   非 prunable の一覧観測を使えば到達可能性を再利用できるが、locked は到達不能になっても
  ///   prunable が付かないので再利用しない。同じパスで作り直された worktree に古い ID を配らない
  ///   よう、Project Root 側の common dir で管理ディレクトリを照合する。
  ///   作業ツリー側の同期 FS 判定を先に撃つと応答しないマウントで打ち切れなくなるため、再利用時も
  ///   呼ばない (`isReachableWorkingTree` の非 prunable に対する制約)。
  /// - Important: 再利用中は、削除後に同じパスで `git init` した別 repository への置き換えや、
  ///   0 バイトの `.git` ファイルなど、prunable が付かず `rev-parse` だけが気づく壊れ方を
  ///   検出できない。呼び出し側は Active 化の直前のスキャンでは `reusableObservations` に空を渡す
  ///   こと (Issue #401)。
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
