import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// Close 検査の merge 判定の再利用 (Issue #366)。commit は不変なので、branch 先端・既定 branch
/// 先端・走査上限が同じなら判定も同じであり、走査をやり直さない。実 git 側の確認は
/// `GitSquashMergeCloseIntegrationTests` が持つ。
@Suite("§3.4 merge 判定を両先端の OID の組で再利用する")
struct GitBranchMergeCacheTests {
  @Test("両先端が同じなら2回目は ancestor 判定も squash 走査も撃たない")
  func reusesJudgementForSameTips() async throws {
    let git = MergeJudgementGit()
    let cache = GitBranchMergeCache()

    let first = try await inspect(git, cache: cache)
    let judgementsAfterFirst = await git.judgementCalls
    let second = try await inspect(git, cache: cache)

    #expect(first.report.inspection.branchMerge == .unmerged)
    #expect(second.report.inspection.branchMerge == .unmerged)
    #expect(judgementsAfterFirst > 0)
    #expect(await git.judgementCalls == judgementsAfterFirst)
  }

  @Test("既定 branch の先端が動いたら判定し直す")
  func judgesAgainWhenTheDefaultBranchMoves() async throws {
    let git = MergeJudgementGit()
    let cache = GitBranchMergeCache()

    _ = try await inspect(git, cache: cache)
    let judgementsAfterFirst = await git.judgementCalls
    await git.moveDefaultBranch(to: String(repeating: "c", count: 40))
    _ = try await inspect(git, cache: cache)

    #expect(await git.judgementCalls > judgementsAfterFirst)
  }

  @Test("判定できなかった回の unknown は再利用しない")
  func doesNotReuseUnknown() async throws {
    let git = MergeJudgementGit(failsDiff: true)
    let cache = GitBranchMergeCache()

    let failed = try await inspect(git, cache: cache)
    await git.recoverDiff()
    let recovered = try await inspect(git, cache: cache)

    #expect(failed.report.inspection.branchMerge == .unknown)
    #expect(recovered.report.inspection.branchMerge == .unmerged)
  }

  @Test("上限を超えた分は古い鍵から捨てる")
  func evictsOldestKeys() async throws {
    let cache = GitBranchMergeCache()
    let keys = try (0...GitBranchMergeCache.capacity).map { index in
      GitBranchMergeCache.Key(
        tip: try #require(CommitObjectID(String(format: "%040x", index))),
        destination: try #require(CommitObjectID(fixtureDefaultTipHex)),
        squashScanCommitLimit: 300)
    }
    for key in keys {
      await cache.store(.unmerged, for: key)
    }

    #expect(await cache.status(for: try #require(keys.first)) == nil)
    #expect(await cache.status(for: try #require(keys.last)) == .unmerged)
  }

  private func inspect(
    _ git: MergeJudgementGit, cache: GitBranchMergeCache
  ) async throws -> GitCloseSafetyInspectionResult {
    let runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: git,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
      isExecutableFile: { _ in true })
    let target = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/topic")),
      worktreePath: "/repo/wt", branch: "topic", isProjectRoot: false)
    return await GitCloseSafetyInspector(runner: runner, target: target, mergeCache: cache)
      .inspect(projectRootBranch: "main")
  }
}

/// 未マージの branch に対する git の応答。ancestor 判定は rc 1、走査の範囲には commit が1つあり、
/// その差分は branch の合成差分と一致しない。
private actor MergeJudgementGit: ProcessRunning {
  private var defaultTip = fixtureDefaultTipHex
  private var failsDiff: Bool
  /// `merge-base` / `log` / `diff` の呼び出し回数。再利用の有無はこれで観測する。
  private(set) var judgementCalls = 0

  init(failsDiff: Bool = false) {
    self.failsDiff = failsDiff
  }

  func moveDefaultBranch(to hex: String) {
    defaultTip = hex
  }

  func recoverDiff() {
    failsDiff = false
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    let command = commandArguments(arguments)
    let candidate = String(repeating: "d", count: 40)
    switch command.first {
    case "status":
      return .init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: "")
    case "symbolic-ref":
      return .init(exitCode: 1, stdout: "", stderr: "")
    case "rev-parse" where command.last == "refs/heads/topic":
      return tipOutput(fixtureTipHex)
    case "rev-parse" where command.last == "refs/heads/main":
      return tipOutput(defaultTip)
    case "merge-base" where command.dropFirst().first == "--is-ancestor":
      judgementCalls += 1
      return .init(exitCode: 1, stdout: "", stderr: "")
    case "merge-base":
      judgementCalls += 1
      return .init(exitCode: 0, stdout: String(repeating: "e", count: 40) + "\n", stderr: "")
    case "log":
      judgementCalls += 1
      let date = "2026-10-08T00:00:00+09:00"
      let record = [
        candidate, "ddddddd", String(repeating: "f", count: 40), "a", "a@example.com", date,
        "c", "c@example.com", date, "s", "s",
      ]
      return .init(exitCode: 0, stdout: record.joined(separator: "\u{1F}") + "\0", stderr: "")
    case "diff":
      judgementCalls += 1
      guard !failsDiff else {
        return .init(exitCode: 128, stdout: "", stderr: "fatal: bad revision\n")
      }
      let isBranchChange = command.contains { $0.hasPrefix(String(repeating: "e", count: 40)) }
      return .init(
        exitCode: 0, stdout: isBranchChange ? "branch-change" : "other-change", stderr: "")
    default:
      throw .launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: "")
    }
  }
}
