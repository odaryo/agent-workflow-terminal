import Foundation
import TerminalCore

enum GitStashList {
  static func undeterminedCount(output: String) -> Int {
    output.utf8.split(separator: 0x0A).count { line in
      guard let prefix = ["WIP on ", "On "].first(where: { line.starts(with: $0.utf8) }) else {
        return true
      }
      let subject = line.dropFirst(prefix.utf8.count)
      guard let separator = subject.firstIndex(of: 0x3A),
        subject[separator...].starts(with: ": ".utf8)
      else { return true }
      return subject[..<separator].elementsEqual("(no branch)".utf8)
    }
  }

  static func count(output: String, branch: String) -> Int {
    // git は branch 名をバイト列で区別する。Character 境界や String の正準等価比較は使わない。
    output.utf8.split(separator: 0x0A).count { line in
      guard let prefix = ["WIP on ", "On "].first(where: { line.starts(with: $0.utf8) }) else {
        return false
      }
      let subject = line.dropFirst(prefix.utf8.count)
      guard let separator = subject.firstIndex(of: 0x3A),
        subject[separator...].starts(with: ": ".utf8)
      else { return false }
      return subject[..<separator].elementsEqual(branch.utf8)
    }
  }
}

public struct GitCloseSafetyInspectionFailure: Error, Sendable, Equatable {
  public enum Check: Sendable, Equatable {
    case uncommittedChanges
    case ignoredFiles
    case branchStashes
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
  /// squash merge を探して既定 branch を**新しい方から**何件走査するか。ここまで見て一致が
  /// 無ければ `.unmerged` (§3.4 — 検出漏れは削除が提示されないだけで安全側)。
  ///
  /// このリポジトリの main の実測 (2026-09-10): 全 146 commit で履歴は 10 日、直近 1 日 21 /
  /// 3 日 66 / 7 日 103 なので、最も速い時期で日 21〜22 commit。300 はその速度の約 14 日分に
  /// あたる。費用は 1 commit あたり `git diff` 1 回で 16〜34 ms (100 commit を 1.59〜1.88 秒、
  /// 別の日の計測で 146 commit を 5.03 秒) なので、上限に張り付く最悪ケースで 5〜10 秒。
  /// この最悪ケースを払うのは一致が最後まで見つからない branch、つまり実際に未マージのときだけ。
  static let defaultSquashScanCommitLimit = 300

  private let runner: GitRunner
  private let target: DetectedWorktree
  private let judge: GitBranchMergeJudge

  public init(
    target: DetectedWorktree,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates,
    mergeCache: GitBranchMergeCache? = nil
  ) throws(GitRunnerError) {
    self.runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: target.worktreePath),
      processRunner: processRunner,
      executableCandidates: executableCandidates, ignoresHistoryRewrites: true)
    self.target = target
    self.judge = GitBranchMergeJudge(
      runner: runner, squashScanCommitLimit: Self.defaultSquashScanCommitLimit,
      mergeCache: mergeCache)
  }

  init(
    runner: GitRunner, target: DetectedWorktree,
    squashScanCommitLimit: Int = Self.defaultSquashScanCommitLimit,
    mergeCache: GitBranchMergeCache? = nil
  ) {
    self.runner = runner
    self.target = target
    self.judge = GitBranchMergeJudge(
      runner: runner, squashScanCommitLimit: squashScanCommitLimit, mergeCache: mergeCache)
  }

  /// `projectRootBranch` は `GitWorktreeDetector` と同じく `refs/heads/` を除いた短縮名だけを受け取る。
  public func inspect(projectRootBranch: String?) async -> GitCloseSafetyInspectionResult {
    var failures: [GitCloseSafetyInspectionFailure] = []
    let targetBranch = target.branch
    let statusChecks = await inspectStatus(targetBranch: targetBranch)
    let ignoredCheck = await inspectIgnoredStatus()
    let stashCheck = await inspectBranchStashes(targetBranch: targetBranch)
    failures += statusChecks.failures
    failures += ignoredCheck.failures
    failures += stashCheck.failures

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
            branchStashes: stashCheck.status,
            unpushedCommits: statusChecks.unpushedCommits,
            branchMerge: .unknown,
            undeterminedStashCount: stashCheck.undeterminedCount),
          defaultBranch: .unresolved(reason: .detachedHead)),
        failures: failures)
    }

    let defaultBranchResult = await judge.resolveDefaultBranch(
      projectRootBranch: projectRootBranch)
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
          branchStashes: stashCheck.status,
          unpushedCommits: statusChecks.unpushedCommits,
          branchMerge: branchMerge,
          undeterminedStashCount: stashCheck.undeterminedCount),
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

  private func inspectBranchStashes(
    targetBranch: String?
  ) async -> StashInspection {
    do {
      let output = try await runner.run(.stashList()).stdout
      let undeterminedCount = GitStashList.undeterminedCount(output: output)
      guard let targetBranch else {
        return .init(status: .notApplicable, undeterminedCount: undeterminedCount, failures: [])
      }
      let count = GitStashList.count(output: output, branch: targetBranch)
      return .init(
        status: count > 0 ? .present(count: count) : .absent,
        undeterminedCount: undeterminedCount, failures: [])
    } catch {
      return .init(
        status: .unknown, undeterminedCount: 0,
        failures: [.init(check: .branchStashes, reason: .git(error))])
    }
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

  private func inspectMerge(
    targetBranch: String,
    defaultRevision: String
  ) async -> (status: BranchMergeStatus, failures: [GitCloseSafetyInspectionFailure]) {
    guard let reference = localBranchRevision(targetBranch) else {
      return (
        .unknown,
        [.init(check: .branchMerge, reason: .invalidRevision("refs/heads/\(targetBranch)"))]
      )
    }
    guard let defaultReference = GitRevision(defaultRevision) else {
      return (
        .unknown, [.init(check: .branchMerge, reason: .invalidRevision(defaultRevision))]
      )
    }
    // 判定は ref 名ではなく、ここで1回読んだ先端の OID に対して行う。ref 名のまま問うと、
    // ancestor 判定と squash 走査がそれぞれ違う時点の先端を読み得るうえ、計画へ載せる先端
    // (`BranchMergeStatus.merged` の `tip`) が判定に使った値だと言えなくなる。既定 branch の
    // 側も同じ理由で OID に固定する —— 加えて、再利用の鍵 (`GitBranchMergeCache`) が
    // 判定に使った既定 branch そのものであることを保証するため (Issue #366)。
    let tip: CommitObjectID
    switch await judge.resolveCommit(reference) {
    case .resolved(let resolved): tip = resolved
    case .failed(let reason): return (.unknown, [.init(check: .branchMerge, reason: reason)])
    }
    let destinationTip: CommitObjectID
    switch await judge.resolveCommit(defaultReference) {
    case .resolved(let resolved): destinationTip = resolved
    case .failed(let reason): return (.unknown, [.init(check: .branchMerge, reason: reason)])
    }
    return await judge.judge(tip: tip, destination: destinationTip)
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

  private struct StashInspection: Sendable {
    let status: BranchStashStatus
    let undeterminedCount: Int
    let failures: [GitCloseSafetyInspectionFailure]
  }

  private struct UnpushedInspection: Sendable {
    let status: UnpushedCommitsStatus
    let failures: [GitCloseSafetyInspectionFailure]
  }
}
