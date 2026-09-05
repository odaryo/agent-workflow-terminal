public enum WorktreeCloseChoice: Sendable, Hashable {
  case hideFromUI
  case terminateSession(AfterSessionTermination)

  public enum AfterSessionTermination: Sendable, Hashable {
    case keepWorktree
    case removeWorktree(AfterWorktreeRemoval)
  }

  public enum AfterWorktreeRemoval: Sendable, Hashable {
    case keepBranch
    case deleteBranch
  }
}

public enum UncommittedChangesStatus: Sendable, Hashable {
  case present
  case absent
  case unknown
}

public enum IgnoredFilesStatus: Sendable, Hashable {
  case present
  case absent
  case unknown
}

public enum UnpushedCommitsStatus: Sendable, Hashable {
  case present
  case absent
  /// upstream 設定だけでは、追跡 ref が未作成なのか prune 済みなのかを区別できない。
  case aheadUnknownWithoutTrackingReference
  case notApplicable
  case unknown
}

public enum BranchMergeStatus: Sendable, Hashable {
  case merged
  case unmerged
  case notApplicable
  case unknown
}

public enum DefaultBranchResolution: Sendable, Hashable {
  public enum UnresolvedReason: Sendable, Hashable {
    case originHeadMissing
    case invalidOriginHead(String)
    case lookupFailed
    case notNeededForDetachedHead
  }

  case originHead(branch: String)
  case projectRoot(branch: String)
  case unresolved(reason: UnresolvedReason)

  public var branch: String? {
    switch self {
    case .originHead(let branch), .projectRoot(let branch): branch
    case .unresolved: nil
    }
  }
}

public struct WorktreeCloseInspection: Sendable, Hashable {
  public let uncommittedChanges: UncommittedChangesStatus
  public let ignoredFiles: IgnoredFilesStatus
  public let unpushedCommits: UnpushedCommitsStatus
  public let branchMerge: BranchMergeStatus

  public init(
    uncommittedChanges: UncommittedChangesStatus,
    ignoredFiles: IgnoredFilesStatus,
    unpushedCommits: UnpushedCommitsStatus,
    branchMerge: BranchMergeStatus
  ) {
    self.uncommittedChanges = uncommittedChanges
    self.ignoredFiles = ignoredFiles
    self.unpushedCommits = unpushedCommits
    self.branchMerge = branchMerge
  }
}

/// §3.4 の選択肢4 (branch も削除する) を提供してよいか。
///
/// - Important: **3つの値が同じ worktree の同じ検査から来ていることは、ここでは確かめられない。**
///   整合は呼び出し側の責務である —— `targetBranch` は対象の `DetectedWorktree.branch`、`merge` は
///   その worktree の検査結果、`defaultBranch` はその `merge` を計算した既定 branch でなければ
///   ならない。この3つを組にできる経路を閉じてあるのは `planWorktreeClose` の側で、あちらは
///   `DetectedWorktree` と `WorktreeRemovalConfirmation` (安定 ID を持ち、検査結果と既定 branch を
///   一組で持つ) だけを受け取り、3つとも自分で導く。UI が選択肢を出せるかを問うためにここを直接
///   呼ぶ場合も、同じ2つの値から導くこと。
///   誤った組で `true` になっても消えるところまでは行かない。`planWorktreeClose` が計画を組む前に
///   同じ判定を自分の導いた3値でやり直すので、実行層へ渡る計画には載らない。誤るのは
///   **提示する選択肢**だけである。
public func isBranchDeletionAvailable(
  targetBranch: String?,
  defaultBranch: DefaultBranchResolution,
  merge: BranchMergeStatus
) -> Bool {
  guard merge == .merged, let targetBranch, let defaultBranch = defaultBranch.branch else {
    return false
  }
  // 暫定措置 (Issue #142 が `DetectedWorktree.branch` の契約を決めるまで)。この値は短縮 local
  // branch 名とは限らない。`git symbolic-ref HEAD refs/foo/bar` を通した worktree では
  // `worktree list --porcelain` が `branch refs/foo/bar` を吐き、`refs/heads/` を剥がす正規化は
  // 何も起きない。未merge検査はこの値を `refs/heads/` で修飾して問うので、git 2.50.1 の実測では
  // 答えが2通りに割れる。
  //
  // - `refs/heads/refs/foo/bar` が存在しない場合: `merge-base --is-ancestor` は rc=128
  //   (`fatal: Not a valid object name refs/heads/refs/foo/bar`) となり `unknown` へ倒れる。
  // - 同名の branch が実在する場合: rc=0 で `merged` へ倒れるが、それは worktree の HEAD とは
  //   **別の ref** についての答えである。実測では、未マージの `refs/foo/bar` を HEAD に持つ
  //   worktree に対して `branch -d refs/foo/bar` が無関係の `refs/heads/refs/foo/bar` を消し、
  //   HEAD 側の commit はそのまま残った。
  //
  // どちらも「この worktree の branch を消した」とは言えないので、契約が決まるまで選択肢4を
  // 提供しない。`feat/refs/x` のように途中に現れる分には影響が無いので前置だけを見る。
  //
  // この guard は偽陰性を伴う。git 2.50.1 実測では `git branch 'refs/x/y'` が rc=0 で通り、その
  // branch を持つ worktree の `worktree list --porcelain` は `branch refs/heads/refs/x/y` を吐く。
  // `refs/heads/` を剥がした値は `refs/x/y` になるので、**実在する正当な branch であっても
  // 選択肢4が永久に提供されない**。安全側なのでこのまま留めるが、Issue #142 が契約を決めるときは
  // 「値が短縮 local branch 名か」と「値が `refs/` 前置を持つか」が別物であることを前提にする。
  guard !targetBranch.hasPrefix("refs/") else { return false }
  return targetBranch != defaultBranch
}
