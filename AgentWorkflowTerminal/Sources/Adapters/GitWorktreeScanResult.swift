import TerminalCore

/// `worktree list` が全 worktree を出し切らなかったこと。どちらの場合も `detected` は不完全である。
public enum GitWorktreeListingFailure: Error, Sendable, Equatable {
  /// git が非 0 で終わり、部分出力の完結 record で続けた。
  case command(GitRunnerError)
  /// git は exit 0 で終わったが、record を黙って欠いた (`GitWorktreeOmission`)。
  case omittedRecords(GitWorktreeOmission)
}

/// git 2.54.0 実測: 管理ディレクトリの `gitdir` を読めない (000・ディレクトリ・空) 場合と、
/// `<common>/worktrees` を読めない場合 (000・444)、`worktree list --porcelain -z` は exit 0・stderr
/// 空のまま、その linked worktree の record を出さない (Issue #774)。空の `gitdir` 以外は 2.39.2 でも
/// 同じだった。
public enum GitWorktreeOmission: Sendable, Equatable {
  /// `<common>/worktrees` を readdir できなかった。いくつ欠けたかは分からない。
  case administrativeDirectoriesUnreadable
  /// 一覧に出るはずの管理ディレクトリの数が、一覧の linked record (prunable を含む) の数より多い。
  /// 数え方は `GitWorktreeDetector.listedAdministrativeDirectoryCount`。
  case missingRecords(administrativeDirectories: Int, linkedRecords: Int)
}

/// - Important: `failures` を捨てて `detected` だけを `reconcileDetectedWorktrees` へ渡すと、
///   失敗した worktree は消失扱いになる (`GitWorktreeDetector` の契約を参照)。
///   `listingFailure` が非 nil のときは `detected` が不完全であり、`isListingComplete: false`
///   も渡さないと、部分出力より後の未検出 worktree が消失扱いになる。
///   `prunable` も渡さないと、不完全な一覧の回に git が prunable と明示した worktree が残る。
public struct GitWorktreeScanResult: Sendable, Equatable {
  public let listingFailure: GitWorktreeListingFailure?
  /// `worktree list` に現れた順。
  public let detected: [DetectedWorktree]
  /// 検出順。同じスキャンで `detected` と同時に立ち得る。
  public let failures: [GitWorktreeEntryFailure]
  /// git が `prunable` を付けた entry の安定 ID (設計書 §3.2.1)。`detected` にも載り得る
  /// (入れないだけの到達不能。Issue #496)。管理ディレクトリを特定できなかった entry は載らない。
  public let prunable: [WorktreeIdentity]

  init(
    detected: [DetectedWorktree], failures: [GitWorktreeEntryFailure],
    listingFailure: GitWorktreeListingFailure? = nil, prunable: [WorktreeIdentity] = []
  ) {
    self.detected = detected
    self.failures = failures
    self.listingFailure = listingFailure
    self.prunable = prunable
  }
}
