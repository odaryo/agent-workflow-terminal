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

public func isBranchDeletionAvailable(
  targetBranch: String?,
  defaultBranch: DefaultBranchResolution,
  merge: BranchMergeStatus
) -> Bool {
  guard merge == .merged, let targetBranch, let defaultBranch = defaultBranch.branch else {
    return false
  }
  return targetBranch != defaultBranch
}
