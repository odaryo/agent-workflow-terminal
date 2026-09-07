import Foundation
import TerminalCore

public enum GitStatusWorktreeStateFailure: Error, Sendable, Equatable {
  case invalidPath(String)
}

public struct GitStatusWorktreeStateResult: Sendable, Equatable {
  public let entries: [WorktreeGitStateEntry]
  public let failures: [GitStatusWorktreeStateFailure]
}

public struct WorktreeGitStateReadResult: Sendable, Equatable {
  public let entries: [WorktreeGitStateEntry]
  public let statusParseFailures: [GitStatusParseFailure]
  public let conversionFailures: [GitStatusWorktreeStateFailure]
}

public struct WorktreeGitStateReader: Sendable {
  private let runner: GitRunner

  public init(
    repositoryDirectory: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    runner = try GitRunner(
      repositoryDirectory: repositoryDirectory,
      processRunner: processRunner,
      executableCandidates: executableCandidates)
  }

  init(runner: GitRunner) {
    self.runner = runner
  }

  public func read() async throws(GitRunnerError) -> WorktreeGitStateReadResult {
    let output = try await runner.run(.status(includeIgnored: true)).stdout
    let parsed = GitStatusPorcelainV2.parse(output: output)
    let converted = parsed.status.worktreeStateEntries()
    return WorktreeGitStateReadResult(
      entries: converted.entries,
      statusParseFailures: parsed.failures,
      conversionFailures: converted.failures)
  }
}

extension GitFileStatusCode {
  public var worktreeStatus: WorktreeGitFileStatus {
    switch self {
    case .unchanged:
      .unchanged
    case .modified:
      .modified
    case .typeChanged:
      .typeChanged
    case .added:
      .added
    case .deleted:
      .deleted
    case .renamed:
      .renamed
    case .copied:
      .copied
    case .unmerged:
      .unmerged
    }
  }
}

extension GitStatus {
  public func worktreeStateEntries() -> GitStatusWorktreeStateResult {
    var result = GitStatusWorktreeStateAccumulator()

    for entry in entries {
      switch entry {
      case .changed(let changed):
        appendTracked(
          path: changed.path,
          index: changed.indexStatus,
          worktree: changed.worktreeStatus,
          makeEntry: WorktreeGitStateEntry.changed,
          result: &result)
      case .unmerged(let unmerged):
        appendTracked(
          path: unmerged.path,
          index: unmerged.indexStatus,
          worktree: unmerged.worktreeStatus,
          makeEntry: WorktreeGitStateEntry.unmerged,
          result: &result)
      case .untracked(let path):
        appendUntrackedOrIgnored(
          path: path, makeEntry: WorktreeGitStateEntry.untracked,
          result: &result)
      case .ignored(let path):
        appendUntrackedOrIgnored(
          path: path, makeEntry: WorktreeGitStateEntry.ignored,
          result: &result)
      }
    }
    return GitStatusWorktreeStateResult(entries: result.entries, failures: result.failures)
  }

  private func appendTracked(
    path: String,
    index: GitFileStatusCode,
    worktree: GitFileStatusCode,
    makeEntry: (WorktreeRelativePath, WorktreeGitFileStatus, WorktreeGitFileStatus) ->
      WorktreeGitStateEntry,
    result: inout GitStatusWorktreeStateAccumulator
  ) {
    guard let relativePath = WorktreeRelativePath(path) else {
      result.failures.append(.invalidPath(path))
      return
    }
    result.entries.append(makeEntry(relativePath, index.worktreeStatus, worktree.worktreeStatus))
  }

  private func appendUntrackedOrIgnored(
    path: String,
    makeEntry: (WorktreeRelativePath, WorktreeGitPathScope) -> WorktreeGitStateEntry,
    result: inout GitStatusWorktreeStateAccumulator
  ) {
    let isDirectory = path.unicodeScalars.last?.value == 0x2F
    let normalizedPath = isDirectory ? String(path.unicodeScalars.dropLast()) : path
    guard let relativePath = WorktreeRelativePath(normalizedPath) else {
      result.failures.append(.invalidPath(path))
      return
    }
    result.entries.append(makeEntry(relativePath, isDirectory ? .directory : .exact))
  }
}

private struct GitStatusWorktreeStateAccumulator {
  var entries: [WorktreeGitStateEntry] = []
  var failures: [GitStatusWorktreeStateFailure] = []
}
