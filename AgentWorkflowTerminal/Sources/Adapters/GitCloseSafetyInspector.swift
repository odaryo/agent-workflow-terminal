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
    case logParse([GitLogParseFailure])
    case missingStatusBranch
    case invalidRevision(String)
  }

  public let check: Check
  public let reason: Reason
}

public struct GitCloseSafetyInspectionResult: Sendable, Equatable {
  public let report: WorktreeCloseInspectionReport
  public let failures: [GitCloseSafetyInspectionFailure]
}

public struct GitCloseSafetyInspector: Sendable {
  /// squash merge を探して走査する既定 branch 側 commit の上限。超えたら `.unmerged` (§3.4)。
  /// 1 commit あたり `git diff` 1 回で、このリポジトリでの実測は 34 ms (146 commit / 5.03 秒) —
  /// 上限に張り付いた最悪ケースで約 7 秒かかる。146 commit はこのリポジトリの main の 30 日分
  /// (直近 7 日で 104) にあたるので、200 は worktree が 2 週間開いたままでも届く範囲になる。
  static let defaultSquashScanCommitLimit = 200

  private let runner: GitRunner
  private let target: DetectedWorktree
  private let squashScanCommitLimit: Int

  public init(
    target: DetectedWorktree,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    self.runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: target.worktreePath),
      processRunner: processRunner,
      executableCandidates: executableCandidates)
    self.target = target
    self.squashScanCommitLimit = Self.defaultSquashScanCommitLimit
  }

  init(
    runner: GitRunner, target: DetectedWorktree,
    squashScanCommitLimit: Int = Self.defaultSquashScanCommitLimit
  ) {
    self.runner = runner
    self.target = target
    self.squashScanCommitLimit = squashScanCommitLimit
  }

  /// `projectRootBranch` は `GitWorktreeDetector` と同じく `refs/heads/` を除いた短縮名だけを受け取る。
  public func inspect(projectRootBranch: String?) async -> GitCloseSafetyInspectionResult {
    var failures: [GitCloseSafetyInspectionFailure] = []
    let targetBranch = target.branch
    let statusChecks = await inspectStatus(targetBranch: targetBranch)
    let ignoredCheck = await inspectIgnoredStatus()
    failures += statusChecks.failures
    failures += ignoredCheck.failures

    guard let targetBranch else {
      // detached HEAD では未push・未merge は「問う必要が無い」のではなく**問えない**。
      // `.notApplicable` へ丸めると、entries が 0 件の detached worktree では §3.4 の 4 検査が
      // すべて無警告になり、到達不能になる commit と中断中の rebase が黙って消える (Issue #244)。
      // 既定 branch の問い合わせだけは省く —— 答えを得ても照合する branch が無いためで、
      // 判定不能であること自体は `.unknown` の側が担う。
      return .init(
        report: .init(
          target: target,
          inspection: .init(
            uncommittedChanges: statusChecks.uncommittedChanges,
            ignoredFiles: ignoredCheck.status,
            unpushedCommits: statusChecks.unpushedCommits,
            branchMerge: .unknown),
          defaultBranch: .unresolved(reason: .detachedHead)),
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
      report: .init(
        target: target,
        inspection: .init(
          uncommittedChanges: statusChecks.uncommittedChanges,
          ignoredFiles: ignoredCheck.status,
          unpushedCommits: statusChecks.unpushedCommits,
          branchMerge: branchMerge),
        defaultBranch: defaultBranchResult.resolution),
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
      return .init(
        uncommittedChanges: .unknown,
        unpushedCommits: .unknown,
        failures: [
          .init(check: .uncommittedChanges, reason: reason),
          .init(check: .unpushedCommits, reason: reason),
        ])
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
      // detached HEAD。upstream を持ち得ない以上 ahead/behind を問えないので判定不能であって、
      // 「未push は無い」ではない (Issue #244)。git 2.50.1 実測でも `status --porcelain=v2` は
      // `# branch.head (detached)` だけを吐き、`# branch.upstream` も `# branch.ab` も出ない。
      return .init(status: .unknown, failures: [])
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
      return await inspectSquashMerge(target: target, destination: destination)
    } catch {
      return (.unknown, [.init(check: .branchMerge, reason: .git(error))])
    }
  }

  /// ancestor 判定に現れない squash merge を、branch の合成差分と既定 branch 側 commit の差分の
  /// 同一性で拾う (§3.4)。検出漏れは「削除が提示されないだけ」なので `.unmerged` へ倒し、
  /// 走査を完遂できなかったときも `.merged` は返さない。
  ///
  /// 比較には `diffFileSummaries` の raw + numstat を使う。git 2.50.1 の実測で、squash merge 前に
  /// 既定 branch が**別のファイルを**変更していても、branch が触ったパスの前後 blob OID は
  /// 変わらないため両者の出力はバイト一致した。同じ実測で `git cherry` は 2 commit 以上の branch を
  /// 1 件も検出できず (全行が `+`)、`git patch-id` は引数のファイルを無視して stdin を待つため
  /// `ProcessRunning` (stdin を渡さない) からは使えない。
  private func inspectSquashMerge(
    target: GitRevision,
    destination: GitRevision
  ) async -> (status: BranchMergeStatus, failures: [GitCloseSafetyInspectionFailure]) {
    do {
      let mergeBaseOutput = try await runner.run(.mergeBase(target, destination)).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let mergeBase = GitRevision(mergeBaseOutput) else {
        return (
          .unknown, [.init(check: .branchMerge, reason: .invalidRevision(mergeBaseOutput))]
        )
      }
      let branchChange = try await changeSummary(from: mergeBase, to: target)
      // 内容差が空の branch は、既定 branch 側の空 commit と一致して `.merged` に化ける
      // (実測: `commit --allow-empty` を1つ持つ既定 branch に対して出力が両方とも空になった)。
      // commit そのものは既定 branch に無いので、これは「マージ済み」ではない。
      guard !branchChange.isEmpty else { return (.unmerged, []) }

      let log = GitLog.parse(
        output: try await runner.run(
          .log(
            range: .twoDot(from: mergeBase, to: destination),
            maxCount: squashScanCommitLimit + 1)
        ).stdout)
      guard log.failures.isEmpty else {
        return (.unknown, [.init(check: .branchMerge, reason: .logParse(log.failures))])
      }
      guard log.commits.count <= squashScanCommitLimit else { return (.unmerged, []) }

      for commit in log.commits {
        // 第1親との差を見る。squash commit は merge commit ではないが、第1親で式を立てておけば
        // 親を持たない commit (無関係な履歴の root) が範囲に混ざっても走査が止まらない。
        guard let parentHash = commit.parentHashes.first,
          let parent = GitRevision(parentHash),
          let commitRevision = GitRevision(commit.hash)
        else { continue }
        if try await changeSummary(from: parent, to: commitRevision) == branchChange {
          return (.merged, [])
        }
      }
      return (.unmerged, [])
    } catch {
      return (.unknown, [.init(check: .branchMerge, reason: .git(error))])
    }
  }

  private func changeSummary(
    from: GitRevision, to: GitRevision
  ) async throws(GitRunnerError) -> String {
    try await runner.run(.diffFileSummaries(.range(.twoDot(from: from, to: to)))).stdout
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
