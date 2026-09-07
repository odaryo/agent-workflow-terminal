public struct WorktreeRelativePath: Sendable, Hashable {
  public let value: String

  /// git が返す正規化済みの worktree 相対パスを受け取る。`?` / `!` の末尾 `/` は呼び出し側が除く。
  public init?(_ value: String) {
    let scalars = value.unicodeScalars
    let components = scalars.split(omittingEmptySubsequences: false) { $0.value == 0x2F }
    guard
      !value.isEmpty,
      scalars.first?.value != 0x2F,
      scalars.last?.value != 0x2F,
      components.allSatisfy({ component in
        !component.isEmpty
          && !(component.count == 1 && component.first?.value == 0x2E)
          && !(component.count == 2 && component.allSatisfy { $0.value == 0x2E })
      })
    else { return nil }
    self.value = value
  }

  fileprivate var depth: Int {
    value.unicodeScalars.reduce(into: 1) { depth, scalar in
      if scalar.value == 0x2F { depth += 1 }
    }
  }

  fileprivate func isWithin(_ directory: Self) -> Bool {
    if self == directory { return true }
    let query = value.unicodeScalars
    let prefix = directory.value.unicodeScalars
    guard query.starts(with: prefix) else { return false }
    return query.dropFirst(prefix.count).first?.value == 0x2F
  }
}

public enum WorktreeGitFileStatus: Sendable, Hashable {
  case unchanged
  case modified
  case typeChanged
  case added
  case deleted
  case renamed
  case copied
  case unmerged
}

public struct WorktreeTrackedFileStatus: Sendable, Hashable {
  public let index: WorktreeGitFileStatus
  public let worktree: WorktreeGitFileStatus

  public static let unchanged = Self(index: .unchanged, worktree: .unchanged)

  public var displayedStatus: WorktreeGitFileStatus {
    worktree == .unchanged ? index : worktree
  }

  public init(index: WorktreeGitFileStatus, worktree: WorktreeGitFileStatus) {
    self.index = index
    self.worktree = worktree
  }
}

public enum WorktreeFileGitState: Sendable, Hashable {
  case tracked(WorktreeTrackedFileStatus)
  case untracked
  case ignored

  public var displayedStatus: WorktreeGitFileStatus? {
    if case .tracked(let status) = self { return status.displayedStatus }
    return nil
  }
}

public enum WorktreeFileKind: Sendable, Hashable {
  case file
  case directory
}

public enum WorktreeGitPathScope: Sendable, Hashable {
  case exact
  /// git の untracked / ignored 出力に末尾 `/` が付いていた場合だけ指定する。
  case directory
}

public enum WorktreeGitStateEntry: Sendable, Hashable {
  /// rename 前のパスは FS 列挙の問い合わせ対象にならないため、rename 後の `path` だけを保持する。
  case changed(
    path: WorktreeRelativePath,
    indexStatus: WorktreeGitFileStatus,
    worktreeStatus: WorktreeGitFileStatus
  )
  case unmerged(
    path: WorktreeRelativePath,
    indexStatus: WorktreeGitFileStatus,
    worktreeStatus: WorktreeGitFileStatus
  )
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
    // 同深さの衝突は git 出力上は生じないが、入力順に結果を依存させないため ignored を優先する。
    path.depth > current.path.depth
      || (path.depth == current.path.depth && state == .ignored)
  }
}

public struct WorktreeFileGitStateOverlay: Sendable, Hashable {
  public let entries: [WorktreeGitStateEntry]

  public init(entries: [WorktreeGitStateEntry]) {
    self.entries = entries
  }

  public func state(
    for path: WorktreeRelativePath,
    kind: WorktreeFileKind
  ) -> WorktreeFileGitState? {
    if let tracked = entries.compactMap({ $0.trackedStatus(for: path) }).first {
      return .tracked(tracked)
    }

    let bestMatch =
      entries.compactMap(\.overlayCandidate).reduce(nil) { current, candidate in
        guard candidate.matches(path) else { return current }
        guard let current else { return candidate }
        return candidate.takesPriority(over: current) ? candidate : current
      } as WorktreeGitOverlayCandidate?
    if let bestMatch { return bestMatch.state }
    return kind == .file ? .tracked(.unchanged) : nil
  }
}

extension WorktreeGitStateEntry {
  fileprivate func trackedStatus(for query: WorktreeRelativePath) -> WorktreeTrackedFileStatus? {
    switch self {
    case .changed(let path, let index, let worktree),
      .unmerged(let path, let index, let worktree):
      guard path == query else { return nil }
      return WorktreeTrackedFileStatus(index: index, worktree: worktree)
    case .untracked, .ignored:
      return nil
    }
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
