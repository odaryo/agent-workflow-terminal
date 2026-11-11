import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// Overview のマージ済みの印 (Issue #879) の判定は、Close の判定 (設計書 §3.4) と同じ規則で
/// 既定 branch を決め、同じ再利用の鍵を使う。実 git 側の確認は
/// `GitBranchMergeProbeIntegrationTests` が持つ。
@Suite("Issue #879 マージ済みの印の判定を git で行う")
struct GitBranchMergeProbeTests {
  @Test("origin/HEAD が無ければ (rc=1) Project Root の branch の先端を既定 branch の先端にする")
  func fallsBackToProjectRootBranch() async throws {
    let git = ProbeGit(originHead: .init(exitCode: 1, stdout: "", stderr: ""))
    let probe = try Self.probe(git)

    #expect(
      await probe.defaultBranchTip(projectRootBranch: "main")
        == CommitObjectID(fixtureDefaultTipHex))
    #expect(
      await git.commands.contains(["rev-parse", "--verify", "--quiet", "refs/heads/main"]))
  }

  @Test("origin/HEAD が指す remote branch の先端を既定 branch の先端にする")
  func resolvesOriginHead() async throws {
    let git = ProbeGit(
      originHead: .init(exitCode: 0, stdout: "refs/remotes/origin/trunk\n", stderr: ""))
    let probe = try Self.probe(git)

    #expect(
      await probe.defaultBranchTip(projectRootBranch: "main")
        == CommitObjectID(ProbeGit.originTrunkTipHex))
    #expect(
      !(await git.commands.contains(["rev-parse", "--verify", "--quiet", "refs/heads/main"])))
  }

  @Test(
    "origin/HEAD が壊れた値・問い合わせの失敗・Project Root の branch も無いときは nil",
    arguments: [
      (ProcessRunResult(exitCode: 0, stdout: "garbage\n", stderr: ""), "main"),
      (ProcessRunResult(exitCode: 128, stdout: "", stderr: "fatal: bad\n"), "main"),
      (ProcessRunResult(exitCode: 1, stdout: "", stderr: ""), nil),
    ] as [(ProcessRunResult, String?)])
  func leavesDefaultBranchTipUndetermined(
    originHead: ProcessRunResult, projectRootBranch: String?
  ) async throws {
    let git = ProbeGit(originHead: originHead)
    let probe = try Self.probe(git)

    #expect(await probe.defaultBranchTip(projectRootBranch: projectRootBranch) == nil)
    #expect(await git.commands.contains { $0.first == "symbolic-ref" })
    #expect(!(await git.commands.contains { $0.first == "rev-parse" }))
  }

  @Test("branchTip は refs/heads/<branch> の先端を返し、無い branch では nil")
  func readsLocalBranchTip() async throws {
    let git = ProbeGit(originHead: .init(exitCode: 1, stdout: "", stderr: ""))
    let probe = try Self.probe(git)

    #expect(await probe.branchTip("topic") == CommitObjectID(fixtureTipHex))
    #expect(await probe.branchTip("missing") == nil)
    #expect(
      await git.commands.contains(["rev-parse", "--verify", "--quiet", "refs/heads/topic"]))
  }

  @Test("replace ref と grafts を無効にして git を呼び、fetch は呼ばない")
  func ignoresHistoryRewritesAndNeverFetches() async throws {
    let git = ProbeGit(originHead: .init(exitCode: 1, stdout: "", stderr: ""))
    // 実行されるのは偽の `ProcessRunning` だけで、ここでは公開の init が要求する「実在する実行
    // ファイル」を満たすためだけに置く。
    let probe = try GitBranchMergeProbe(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: git,
      mergeCache: GitBranchMergeCache(),
      executableCandidates: [URL(fileURLWithPath: "/bin/sh")])

    let tip = try #require(await probe.branchTip("topic"))
    let destination = try #require(await probe.defaultBranchTip(projectRootBranch: "main"))
    _ = await probe.mergeStatus(tip: tip, destination: destination)

    let environments = await git.environments
    try #require(!environments.isEmpty)
    #expect(environments.allSatisfy { $0["GIT_NO_REPLACE_OBJECTS"] == "1" })
    #expect(environments.allSatisfy { $0["GIT_GRAFT_FILE"] != nil })
    #expect(!(await git.commands.contains { $0.contains("fetch") }))
  }

  @Test("判定は ancestor 判定と同じ答えを返し、同じ両先端の2回目は git を呼ばない")
  func judgesAncestorAndReusesTheAnswer() async throws {
    let git = ProbeGit(originHead: .init(exitCode: 1, stdout: "", stderr: ""))
    let probe = try Self.probe(git)
    let tip = try #require(CommitObjectID(fixtureTipHex))
    let destination = try #require(CommitObjectID(fixtureDefaultTipHex))

    let first = await probe.mergeStatus(tip: tip, destination: destination)
    let judgementsAfterFirst = await git.ancestorQueries
    let second = await probe.mergeStatus(tip: tip, destination: destination)

    #expect(first == .merged(.ancestor, tip: tip))
    #expect(second == .merged(.ancestor, tip: tip))
    #expect(judgementsAfterFirst == 1)
    #expect(await git.ancestorQueries == 1)
  }

  @Test("probe の判定は Close と同じ鍵で保存され、両先端が同じなら Close が再利用する")
  func closeReusesProbeJudgementForTheSameTips() async throws {
    let git = ProbeGit(originHead: .init(exitCode: 1, stdout: "", stderr: ""))
    let cache = GitBranchMergeCache()
    let tip = try #require(CommitObjectID(fixtureTipHex))
    let destination = try #require(CommitObjectID(fixtureDefaultTipHex))

    let probed = await GitBranchMergeProbe(runner: try Self.runner(git), mergeCache: cache)
      .mergeStatus(tip: tip, destination: destination)
    try #require(probed == .merged(.ancestor, tip: tip))
    let queriesAfterProbe = await git.ancestorQueries
    let inspected = try await Self.inspectClose(git, cache: cache)

    #expect(inspected == .merged(.ancestor, tip: tip))
    #expect(await git.ancestorQueries == queriesAfterProbe)
  }

  @Test("probe がマージ済みと判定した後でも、既定 branch の先端が違えば Close は判定し直す")
  func closeRejudgesWhenDefaultBranchDiffers() async throws {
    let git = ProbeGit(originHead: .init(exitCode: 1, stdout: "", stderr: ""))
    let cache = GitBranchMergeCache()
    let tip = try #require(CommitObjectID(fixtureTipHex))
    let probedDestination = try #require(CommitObjectID(fixtureDefaultTipHex))

    let probed = await GitBranchMergeProbe(runner: try Self.runner(git), mergeCache: cache)
      .mergeStatus(tip: tip, destination: probedDestination)
    try #require(probed == .merged(.ancestor, tip: tip))
    let queriesAfterProbe = await git.ancestorQueries
    await git.moveDefaultBranch(to: String(repeating: "c", count: 40))
    _ = try await Self.inspectClose(git, cache: cache)

    #expect(await git.ancestorQueries == queriesAfterProbe + 1)
  }

  private static func runner(_ git: ProbeGit) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: git,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
      isExecutableFile: { _ in true })
  }

  private static func probe(_ git: ProbeGit) throws -> GitBranchMergeProbe {
    GitBranchMergeProbe(runner: try runner(git), mergeCache: GitBranchMergeCache())
  }

  private static func inspectClose(
    _ git: ProbeGit, cache: GitBranchMergeCache
  ) async throws -> BranchMergeStatus {
    let target = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/topic")),
      worktreePath: "/repo/wt", branch: "topic", isProjectRoot: false)
    return await GitCloseSafetyInspector(runner: try runner(git), target: target, mergeCache: cache)
      .inspect(projectRootBranch: "main").report.inspection.branchMerge
  }
}

/// `refs/heads/topic` が `fixtureTipHex`、`refs/heads/main` が既定 branch の先端で、ancestor 判定は
/// 常に rc=0 (マージ済み) を返す git。知らないコマンドは起動の失敗にする。
private actor ProbeGit: ProcessRunning {
  static let originTrunkTipHex = String(repeating: "7", count: 40)

  private let originHead: ProcessRunResult
  private var defaultTip = fixtureDefaultTipHex
  private(set) var commands: [[String]] = []
  private(set) var environments: [[String: String]] = []
  private(set) var ancestorQueries = 0

  init(originHead: ProcessRunResult) {
    self.originHead = originHead
  }

  func moveDefaultBranch(to hex: String) {
    defaultTip = hex
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    let command = commandArguments(arguments)
    commands.append(command)
    environments.append(environment)
    switch command.first {
    case "status":
      return .init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: "")
    case "stash" where command == GitReadCommand.stashList().arguments:
      return .init(exitCode: 0, stdout: "", stderr: "")
    case "symbolic-ref":
      return originHead
    case "rev-parse" where command.last == "refs/heads/topic":
      return tipOutput(fixtureTipHex)
    case "rev-parse" where command.last == "refs/heads/main":
      return tipOutput(defaultTip)
    case "rev-parse" where command.last == "refs/remotes/origin/trunk":
      return tipOutput(Self.originTrunkTipHex)
    case "rev-parse":
      return .init(exitCode: 1, stdout: "", stderr: "")
    case "merge-base" where command.dropFirst().first == "--is-ancestor":
      ancestorQueries += 1
      return .init(exitCode: 0, stdout: "", stderr: "")
    default:
      throw .launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: "")
    }
  }
}
