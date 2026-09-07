public struct WorktreeRelativePath: Sendable, Hashable {
  public let value: String

  public init?(_ value: String) {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !value.isEmpty,
      !value.hasPrefix("/"),
      !value.hasSuffix("/"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { return nil }
    self.value = value
  }

  fileprivate var depth: Int {
    value.reduce(into: 1) { depth, character in
      if character == "/" { depth += 1 }
    }
  }

  fileprivate func isWithin(_ directory: Self) -> Bool {
    self == directory || value.hasPrefix(directory.value + "/")
  }
}

public enum WorktreeFileChange: Sendable, Hashable {
  case modified
  case added
  case deleted
  case renamed
}

public enum WorktreeTrackedFileState: Sendable, Hashable {
  case unchanged
  case modified
  case added
  case deleted
  case renamed
  case unmerged
}

public enum WorktreeFileGitState: Sendable, Hashable {
  case tracked(WorktreeTrackedFileState)
  case untracked
  case ignored
}

public enum WorktreeGitPathScope: Sendable, Hashable {
  case exact
  case directory
}

public enum WorktreeGitStateEntry: Sendable, Hashable {
  case changed(path: WorktreeRelativePath, change: WorktreeFileChange)
  case unmerged(path: WorktreeRelativePath)
  case untracked(path: WorktreeRelativePath, scope: WorktreeGitPathScope)
  case ignored(path: WorktreeRelativePath, scope: WorktreeGitPathScope)
}

private struct WorktreeGitOverlayCandidate {
  let path: WorktreeRelativePath
  let scope: WorktreeGitPathScope
  let state: WorktreeFileGitState

  func matches(_ query: WorktreeRelativePath) -> Bool {
    scope == .exact ? path == query : query.isWithin(path)
  }

  func takesPriority(over current: Self) -> Bool {
    path.depth > current.path.depth
      || (path.depth == current.path.depth && state == .ignored)
  }
}

public struct WorktreeFileGitStateOverlay: Sendable, Hashable {
  public let entries: [WorktreeGitStateEntry]

  public init(entries: [WorktreeGitStateEntry]) {
    self.entries = entries
  }

  public func state(for path: WorktreeRelativePath) -> WorktreeFileGitState {
    if entries.contains(where: { $0.isUnmerged(path) }) { return .tracked(.unmerged) }
    if let changed = entries.compactMap({ $0.changedState(for: path) }).first {
      return .tracked(changed)
    }

    let bestMatch =
      entries.compactMap(\.overlayCandidate).reduce(nil) { current, candidate in
        guard candidate.matches(path) else { return current }
        guard let current else { return candidate }
        return candidate.takesPriority(over: current) ? candidate : current
      } as WorktreeGitOverlayCandidate?
    return bestMatch?.state ?? .tracked(.unchanged)
  }
}

extension WorktreeGitStateEntry {
  fileprivate func isUnmerged(_ query: WorktreeRelativePath) -> Bool {
    if case .unmerged(let path) = self { return path == query }
    return false
  }

  fileprivate func changedState(for query: WorktreeRelativePath) -> WorktreeTrackedFileState? {
    if case .changed(let path, let change) = self, path == query {
      return change.trackedState
    }
    return nil
  }

  fileprivate var overlayCandidate: WorktreeGitOverlayCandidate? {
    switch self {
    case .changed, .unmerged:
      nil
    case .untracked(let path, let scope):
      WorktreeGitOverlayCandidate(path: path, scope: scope, state: .untracked)
    case .ignored(let path, let scope):
      WorktreeGitOverlayCandidate(path: path, scope: scope, state: .ignored)
    }
  }
}

extension WorktreeFileChange {
  fileprivate var trackedState: WorktreeTrackedFileState {
    switch self {
    case .modified:
      .modified
    case .added:
      .added
    case .deleted:
      .deleted
    case .renamed:
      .renamed
    }
  }
}
