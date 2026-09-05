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

public enum UnpushedCommitsStatus: Sendable, Hashable {
  case present
  case absent
  case notApplicable
  case unknown
}

public enum BranchMergeStatus: Sendable, Hashable {
  case merged
  case unmerged
  case notApplicable
  case unknown
}

public struct WorktreeCloseInspection: Sendable, Hashable {
  public let uncommittedChanges: UncommittedChangesStatus
  public let unpushedCommits: UnpushedCommitsStatus
  public let branchMerge: BranchMergeStatus

  public init(
    uncommittedChanges: UncommittedChangesStatus,
    unpushedCommits: UnpushedCommitsStatus,
    branchMerge: BranchMergeStatus
  ) {
    self.uncommittedChanges = uncommittedChanges
    self.unpushedCommits = unpushedCommits
    self.branchMerge = branchMerge
  }
}

public func isBranchDeletionAvailable(
  targetBranch: String?,
  defaultBranch: String?,
  merge: BranchMergeStatus
) -> Bool {
  guard merge == .merged, let targetBranch, let defaultBranch else { return false }
  return targetBranch != defaultBranch
}
