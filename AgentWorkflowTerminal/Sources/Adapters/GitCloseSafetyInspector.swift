import Foundation
import TerminalCore

public struct GitCloseSafetyInspectionFailure: Error, Sendable, Equatable {
  public enum Check: Sendable, Equatable {
    case uncommittedChanges
    case unpushedCommits
    case branchMerge
  }

  public enum Reason: Sendable, Equatable {
    case git(GitRunnerError)
    case statusParse([GitStatusParseFailure])
    case missingStatusBranch
    case missingAhead
    case invalidOriginHead(String)
    case invalidRevision(String)
  }

  public let check: Check
  public let reason: Reason
}

public struct GitCloseSafetyInspectionResult: Sendable, Equatable {
  public let inspection: WorktreeCloseInspection
  public let defaultBranch: String?
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
    detectedWorktrees: [DetectedWorktree]
  ) async -> GitCloseSafetyInspectionResult {
    var failures: [GitCloseSafetyInspectionFailure] = []
    let statusChecks = await inspectStatus(targetBranch: targetBranch)
    failures += statusChecks.failures

    guard let targetBranch else {
      return .init(
        inspection: .init(
          uncommittedChanges: statusChecks.uncommittedChanges,
          unpushedCommits: .notApplicable,
          branchMerge: .notApplicable),
        defaultBranch: nil,
        failures: failures)
    }

    let defaultBranchResult = await resolveDefaultBranch(detectedWorktrees: detectedWorktrees)
    failures += defaultBranchResult.failures
    let branchMerge: BranchMergeStatus
    if let defaultBranch = defaultBranchResult.branch {
      let mergeResult = await inspectMerge(
        targetBranch: targetBranch, defaultRevision: defaultBranch.revision)
      branchMerge = mergeResult.status
      failures += mergeResult.failures
    } else {
      branchMerge = .unknown
    }

    return .init(
      inspection: .init(
        uncommittedChanges: statusChecks.uncommittedChanges,
        unpushedCommits: statusChecks.unpushedCommits,
        branchMerge: branchMerge),
      defaultBranch: defaultBranchResult.branch?.name,
      failures: failures)
  }

  private func inspectStatus(
    targetBranch: String?
  ) async -> StatusInspection {
    let output: String
    do {
      output = try await runner.run(.status()).stdout
    } catch {
      let reason = GitCloseSafetyInspectionFailure.Reason.git(error)
      var failures = [
        GitCloseSafetyInspectionFailure(check: .uncommittedChanges, reason: reason)
      ]
      if targetBranch != nil {
        failures.append(.init(check: .unpushedCommits, reason: reason))
      }
      return .init(
        uncommittedChanges: .unknown,
        unpushedCommits: targetBranch == nil ? .notApplicable : .unknown,
        failures: failures)
    }

    return interpretStatus(output, targetBranch: targetBranch)
  }

  private func interpretStatus(_ output: String, targetBranch: String?) -> StatusInspection {
    let parsed = GitStatusPorcelainV2.parse(output: output)
    let uncommittedChanges: UncommittedChangesStatus
    var failures: [GitCloseSafetyInspectionFailure] = []
    if parsed.failures.isEmpty {
      uncommittedChanges =
        parsed.status.entries.contains { entry in
          if case .ignored = entry { return false }
          return true
        } ? .present : .absent
    } else {
      uncommittedChanges = .unknown
      failures.append(.init(check: .uncommittedChanges, reason: .statusParse(parsed.failures)))
    }

    guard targetBranch != nil else {
      return .init(
        uncommittedChanges: uncommittedChanges,
        unpushedCommits: .notApplicable,
        failures: failures)
    }
    guard let branch = parsed.status.branch else {
      failures.append(.init(check: .unpushedCommits, reason: .missingStatusBranch))
      return .init(
        uncommittedChanges: uncommittedChanges,
        unpushedCommits: .unknown,
        failures: failures)
    }
    guard !branch.isDetached else {
      return .init(
        uncommittedChanges: uncommittedChanges,
        unpushedCommits: .notApplicable,
        failures: failures)
    }
    guard branch.upstream != nil else {
      return .init(
        uncommittedChanges: uncommittedChanges,
        unpushedCommits: .present,
        failures: failures)
    }
    guard let ahead = branch.ahead else {
      failures.append(.init(check: .unpushedCommits, reason: .missingAhead))
      return .init(
        uncommittedChanges: uncommittedChanges,
        unpushedCommits: .unknown,
        failures: failures)
    }
    return .init(
      uncommittedChanges: uncommittedChanges,
      unpushedCommits: ahead > 0 ? .present : .absent,
      failures: failures)
  }

  private func resolveDefaultBranch(
    detectedWorktrees: [DetectedWorktree]
  ) async -> (branch: ResolvedDefaultBranch?, failures: [GitCloseSafetyInspectionFailure]) {
    var failures: [GitCloseSafetyInspectionFailure] = []
    do {
      let output = try await runner.run(.originHead()).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let prefix = "refs/remotes/origin/"
      if output.hasPrefix(prefix), output.count > prefix.count {
        return (
          .init(name: String(output.dropFirst(prefix.count)), revision: output), failures
        )
      }
      failures.append(.init(check: .branchMerge, reason: .invalidOriginHead(output)))
    } catch GitRunnerError.commandFailed(let exitCode, _, _) where exitCode == 1 {
      // --quiet の exit 1 は symbolic ref が無いという正常なフォールバック条件。
    } catch {
      failures.append(.init(check: .branchMerge, reason: .git(error)))
    }

    let projectRootBranch = detectedWorktrees.first(where: \.isProjectRoot)?.branch
    return (projectRootBranch.map { .init(name: $0, revision: $0) }, failures)
  }

  private func inspectMerge(
    targetBranch: String,
    defaultRevision: String
  ) async -> (status: BranchMergeStatus, failures: [GitCloseSafetyInspectionFailure]) {
    guard let target = GitRevision(targetBranch) else {
      return (
        .unknown, [.init(check: .branchMerge, reason: .invalidRevision(targetBranch))]
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

  private struct ResolvedDefaultBranch: Sendable {
    let name: String
    let revision: String
  }

  private struct StatusInspection: Sendable {
    let uncommittedChanges: UncommittedChangesStatus
    let unpushedCommits: UnpushedCommitsStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }
}
