import Foundation
import TerminalCore

public struct GitCloseSafetyInspectionFailure: Error, Sendable, Equatable {
  public enum Check: Sendable, Equatable {
    case uncommittedChanges
    case ignoredFiles
    case unpushedCommits
    case branchMerge
  }

  public enum Reason: Sendable, Equatable {
    case git(GitRunnerError)
    case statusParse([GitStatusParseFailure])
    case missingStatusBranch
    case invalidRevision(String)
  }

  public let check: Check
  public let reason: Reason
}

public struct GitCloseSafetyInspectionResult: Sendable, Equatable {
  public let inspection: WorktreeCloseInspection
  public let defaultBranch: DefaultBranchResolution
  public let failures: [GitCloseSafetyInspectionFailure]
}

public struct GitCloseSafetyInspector: Sendable {
  private let runner: GitRunner
  private let targetBranch: String?

  public init(
    target: DetectedWorktree,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    self.runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: target.worktreePath),
      processRunner: processRunner,
      executableCandidates: executableCandidates)
    self.targetBranch = target.branch
  }

  init(runner: GitRunner, targetBranch: String?) {
    self.runner = runner
    self.targetBranch = targetBranch
  }

  public func inspect(
    projectRootBranch: String?
  ) async -> GitCloseSafetyInspectionResult {
    var failures: [GitCloseSafetyInspectionFailure] = []
    let statusChecks = await inspectStatus(targetBranch: targetBranch)
    failures += statusChecks.failures

    guard let targetBranch else {
      return .init(
        inspection: .init(
          uncommittedChanges: statusChecks.uncommittedChanges,
          ignoredFiles: statusChecks.ignoredFiles,
          unpushedCommits: .notApplicable,
          branchMerge: .notApplicable),
        defaultBranch: .unresolved,
        failures: failures)
    }

    let defaultBranchResult = await resolveDefaultBranch(projectRootBranch: projectRootBranch)
    failures += defaultBranchResult.failures
    let branchMerge: BranchMergeStatus
    if let defaultRevision = defaultBranchResult.revision {
      let mergeResult = await inspectMerge(
        targetBranch: targetBranch, defaultRevision: defaultRevision)
      branchMerge = mergeResult.status
      failures += mergeResult.failures
    } else {
      branchMerge = .unknown
    }

    return .init(
      inspection: .init(
        uncommittedChanges: statusChecks.uncommittedChanges,
        ignoredFiles: statusChecks.ignoredFiles,
        unpushedCommits: statusChecks.unpushedCommits,
        branchMerge: branchMerge),
      defaultBranch: defaultBranchResult.resolution,
      failures: failures)
  }

  private func inspectStatus(
    targetBranch: String?
  ) async -> StatusInspection {
    let output: String
    do {
      output = try await runner.run(.status(includeIgnored: true)).stdout
    } catch {
      let reason = GitCloseSafetyInspectionFailure.Reason.git(error)
      var failures = [
        GitCloseSafetyInspectionFailure(check: .uncommittedChanges, reason: reason),
        GitCloseSafetyInspectionFailure(check: .ignoredFiles, reason: reason),
      ]
      if targetBranch != nil {
        failures.append(.init(check: .unpushedCommits, reason: reason))
      }
      return .init(
        uncommittedChanges: .unknown,
        ignoredFiles: .unknown,
        unpushedCommits: targetBranch == nil ? .notApplicable : .unknown,
        failures: failures)
    }

    return interpretStatus(output, targetBranch: targetBranch)
  }

  private func interpretStatus(_ output: String, targetBranch: String?) -> StatusInspection {
    let parsed = GitStatusPorcelainV2.parse(output: output)
    let files = inspectFiles(parsed)
    let unpushed = inspectUnpushed(parsed, targetBranch: targetBranch)
    return .init(
      uncommittedChanges: files.uncommittedChanges,
      ignoredFiles: files.ignoredFiles,
      unpushedCommits: unpushed.status,
      failures: files.failures + unpushed.failures)
  }

  private func inspectFiles(_ parsed: GitStatusParseResult) -> FileInspection {
    if parsed.failures.isEmpty {
      let uncommittedChanges: UncommittedChangesStatus =
        parsed.status.entries.contains { entry in
          if case .ignored = entry { return false }
          return true
        } ? .present : .absent
      let ignoredFiles: IgnoredFilesStatus =
        parsed.status.entries.contains { entry in
          if case .ignored = entry { return true }
          return false
        } ? .present : .absent
      return .init(
        uncommittedChanges: uncommittedChanges, ignoredFiles: ignoredFiles, failures: [])
    }
    let reason = GitCloseSafetyInspectionFailure.Reason.statusParse(parsed.failures)
    return .init(
      uncommittedChanges: .unknown,
      ignoredFiles: .unknown,
      failures: [
        .init(check: .uncommittedChanges, reason: reason),
        .init(check: .ignoredFiles, reason: reason),
      ])
  }

  private func inspectUnpushed(
    _ parsed: GitStatusParseResult,
    targetBranch: String?
  ) -> UnpushedInspection {
    guard targetBranch != nil else {
      return .init(status: .notApplicable, failures: [])
    }
    guard let branch = parsed.status.branch else {
      return .init(
        status: .unknown, failures: [.init(check: .unpushedCommits, reason: .missingStatusBranch)])
    }
    guard !branch.isDetached else {
      // porcelain v2 では同名の実在 branch `(detached)` と detached HEAD を区別できない。
      return .init(status: .notApplicable, failures: [])
    }
    guard branch.upstream != nil else {
      return .init(status: .present, failures: [])
    }
    let aheadBehindFailures = parsed.failures.filter {
      if case .invalidBranchAheadBehind = $0.error { return true }
      return false
    }
    guard aheadBehindFailures.isEmpty else {
      return .init(
        status: .unknown,
        failures: [.init(check: .unpushedCommits, reason: .statusParse(aheadBehindFailures))])
    }
    guard let ahead = branch.ahead else {
      return .init(status: .trackingBranchMissing, failures: [])
    }
    return .init(status: ahead > 0 ? .present : .absent, failures: [])
  }

  private func resolveDefaultBranch(
    projectRootBranch: String?
  ) async -> DefaultBranchInspection {
    do {
      let output = try await runner.run(.originHead()).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let branch = Self.remoteBranchName(from: output) else {
        return .init(resolution: .unresolved, revision: nil, failures: [])
      }
      return .init(
        resolution: .originHead(branch: branch), revision: output, failures: [])
    } catch GitRunnerError.commandFailed(let exitCode, _, _) where exitCode == 1 {
      // --quiet の exit 1 は symbolic ref が無いという正常なフォールバック条件。
      guard let projectRootBranch else {
        return .init(resolution: .unresolved, revision: nil, failures: [])
      }
      return .init(
        resolution: .projectRoot(branch: Self.shortBranchName(projectRootBranch)),
        revision: Self.localBranchRevision(projectRootBranch),
        failures: [])
    } catch {
      return .init(
        resolution: .unresolved,
        revision: nil,
        failures: [.init(check: .branchMerge, reason: .git(error))])
    }
  }

  private func inspectMerge(
    targetBranch: String,
    defaultRevision: String
  ) async -> (status: BranchMergeStatus, failures: [GitCloseSafetyInspectionFailure]) {
    let targetRevision = Self.localBranchRevision(targetBranch)
    guard let target = GitRevision(targetRevision) else {
      return (
        .unknown, [.init(check: .branchMerge, reason: .invalidRevision(targetRevision))]
      )
    }
    guard let destination = GitRevision(defaultRevision) else {
      return (
        .unknown, [.init(check: .branchMerge, reason: .invalidRevision(defaultRevision))]
      )
    }
    do {
      _ = try await runner.run(.isAncestor(target, of: destination))
      return (.merged, [])
    } catch GitRunnerError.commandFailed(let exitCode, _, _) where exitCode == 1 {
      return (.unmerged, [])
    } catch {
      return (.unknown, [.init(check: .branchMerge, reason: .git(error))])
    }
  }

  private static func localBranchRevision(_ branch: String) -> String {
    branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"
  }

  private static func shortBranchName(_ branch: String) -> String {
    let prefix = "refs/heads/"
    return branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
  }

  private static func remoteBranchName(from revision: String) -> String? {
    let prefix = "refs/remotes/"
    guard revision.hasPrefix(prefix) else { return nil }
    let remoteAndBranch = revision.dropFirst(prefix.count)
    guard let separator = remoteAndBranch.firstIndex(of: "/") else { return nil }
    let remote = remoteAndBranch[..<separator]
    let branch = remoteAndBranch[remoteAndBranch.index(after: separator)...]
    guard !remote.isEmpty, !branch.isEmpty else { return nil }
    return String(branch)
  }

  private struct DefaultBranchInspection: Sendable {
    let resolution: DefaultBranchResolution
    let revision: String?
    let failures: [GitCloseSafetyInspectionFailure]
  }

  private struct StatusInspection: Sendable {
    let uncommittedChanges: UncommittedChangesStatus
    let ignoredFiles: IgnoredFilesStatus
    let unpushedCommits: UnpushedCommitsStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }

  private struct FileInspection: Sendable {
    let uncommittedChanges: UncommittedChangesStatus
    let ignoredFiles: IgnoredFilesStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }

  private struct UnpushedInspection: Sendable {
    let status: UnpushedCommitsStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }
}
