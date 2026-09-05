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

  /// `projectRootBranch` は `GitWorktreeDetector` と同じく `refs/heads/` を除いた短縮名だけを受け取る。
  public func inspect(projectRootBranch: String?) async -> GitCloseSafetyInspectionResult {
    var failures: [GitCloseSafetyInspectionFailure] = []
    let statusChecks = await inspectStatus(targetBranch: targetBranch)
    let ignoredCheck = await inspectIgnoredStatus()
    failures += statusChecks.failures
    failures += ignoredCheck.failures

    guard let targetBranch else {
      // branch が無ければ未mergeを問えないので、既定branchの問い合わせ自体を省く。
      return .init(
        inspection: .init(
          uncommittedChanges: statusChecks.uncommittedChanges,
          ignoredFiles: ignoredCheck.status,
          unpushedCommits: .notApplicable,
          branchMerge: .notApplicable),
        defaultBranch: .unresolved(reason: .notNeededForDetachedHead),
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
        ignoredFiles: ignoredCheck.status,
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
    let uncommitted = inspectUncommitted(parsed)
    let unpushed = inspectUnpushed(parsed, targetBranch: targetBranch)
    return .init(
      uncommittedChanges: uncommitted.status,
      unpushedCommits: unpushed.status,
      failures: uncommitted.failures + unpushed.failures)
  }

  private func inspectUncommitted(_ parsed: GitStatusParseResult) -> UncommittedInspection {
    if parsed.failures.isEmpty {
      return .init(
        status: parsed.status.entries.isEmpty ? .absent : .present, failures: [])
    }
    let reason = GitCloseSafetyInspectionFailure.Reason.statusParse(parsed.failures)
    return .init(
      status: .unknown, failures: [.init(check: .uncommittedChanges, reason: reason)])
  }

  private func inspectIgnoredStatus() async -> IgnoredInspection {
    let output: String
    do {
      output = try await runner.run(.status(includeIgnored: true)).stdout
    } catch {
      return .init(status: .unknown, failures: [.init(check: .ignoredFiles, reason: .git(error))])
    }
    let parsed = GitStatusPorcelainV2.parse(output: output)
    guard parsed.failures.isEmpty else {
      return .init(
        status: .unknown,
        failures: [.init(check: .ignoredFiles, reason: .statusParse(parsed.failures))])
    }
    let hasIgnored = parsed.status.entries.contains { entry in
      if case .ignored = entry { return true }
      return false
    }
    return .init(status: hasIgnored ? .present : .absent, failures: [])
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
      return .init(status: .aheadUnknownWithoutTrackingReference, failures: [])
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
        return .init(
          resolution: .unresolved(reason: .invalidOriginHead(output)), revision: nil,
          failures: [])
      }
      return .init(
        resolution: .originHead(branch: branch), revision: output, failures: [])
    } catch GitRunnerError.commandFailed(let exitCode, _, _) where exitCode == 1 {
      // --quiet の exit 1 は symbolic ref が無いという正常なフォールバック条件。
      guard let projectRootBranch else {
        return .init(
          resolution: .unresolved(reason: .originHeadMissing), revision: nil, failures: [])
      }
      return .init(
        resolution: .projectRoot(branch: projectRootBranch),
        revision: Self.localBranchRevision(projectRootBranch),
        failures: [])
    } catch {
      return .init(
        resolution: .unresolved(reason: .lookupFailed),
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
    "refs/heads/\(branch)"
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
    let unpushedCommits: UnpushedCommitsStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }

  private struct UncommittedInspection: Sendable {
    let status: UncommittedChangesStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }

  private struct IgnoredInspection: Sendable {
    let status: IgnoredFilesStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }

  private struct UnpushedInspection: Sendable {
    let status: UnpushedCommitsStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }
}
