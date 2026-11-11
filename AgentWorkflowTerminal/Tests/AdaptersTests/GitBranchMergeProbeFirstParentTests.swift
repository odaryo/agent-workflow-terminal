import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// `rev-list --first-parent --parents <dest> ^<tip>` の最後の行は、dest から first-parent を辿って
/// tip の祖先に当たる直前の commit とその親。その第1親が tip なら、tip は first-parent の列の上に
/// ある (Issue #879、git 2.54.0 で計測)。実 git 側の確認は `GitBranchMergeProbeIntegrationTests`。
private let tipHex = String(repeating: "a", count: 40)
private let destinationHex = String(repeating: "b", count: 40)
private let middleHex = String(repeating: "c", count: 40)
private let sideHex = String(repeating: "e", count: 40)

@Suite("Issue #879 先端が既定 branch の first-parent の列の上にあるかを git で読む")
struct GitBranchMergeProbeFirstParentTests {
  @Test(
    "最後の行の第1親が先端なら true、第2親以降や別の commit なら false",
    arguments: [
      ("\(destinationHex) \(middleHex)\n\(middleHex) \(tipHex)\n", true),
      ("\(destinationHex) \(middleHex) \(sideHex)\n\(middleHex) \(tipHex) \(sideHex)\n", true),
      ("\(destinationHex) \(middleHex) \(tipHex)\n", false),
      ("\(destinationHex) \(middleHex)\n\(middleHex) \(sideHex)\n", false),
    ] as [(String, Bool)])
  func readsFirstParentOfTheLastLine(output: String, expected: Bool) async throws {
    let git = FirstParentGit(revList: .init(exitCode: 0, stdout: output, stderr: ""))
    let probe = try Self.probe(git)

    #expect(
      await probe.isOnFirstParentChain(
        tip: try Self.oid(tipHex), destination: try Self.oid(destinationHex))
        == expected)
    #expect(
      await git.commands == [
        ["rev-list", "--first-parent", "--parents", destinationHex, "^" + tipHex]
      ])
  }

  @Test("先端と既定 branch の先端が同じなら true")
  func sameCommitIsOnTheChain() async throws {
    let git = FirstParentGit(revList: .init(exitCode: 0, stdout: "", stderr: ""))
    let probe = try Self.probe(git)
    let tip = try Self.oid(tipHex)

    #expect(await probe.isOnFirstParentChain(tip: tip, destination: tip) == true)
  }

  /// 出力が空 (既定 branch が先端の祖先) と、最後が親の無い行 (先端が既定 branch の祖先でない) は、
  /// ancestor でマージ済みと判定した後には起きないはずの形なので、判定できなかったものとして扱う。
  @Test(
    "git が失敗したとき・行を解釈できないとき・出力が空のとき・最後が親の無い行のときは nil",
    arguments: [
      ProcessRunResult(exitCode: 128, stdout: "", stderr: "fatal: bad revision\n"),
      ProcessRunResult(exitCode: 0, stdout: "garbage line\n", stderr: ""),
      ProcessRunResult(exitCode: 0, stdout: "", stderr: ""),
      ProcessRunResult(
        exitCode: 0, stdout: "\(destinationHex) \(middleHex)\n\(middleHex)\n", stderr: ""),
    ])
  func leavesUnreadableOutputUndetermined(revList: ProcessRunResult) async throws {
    let git = FirstParentGit(revList: revList)
    let probe = try Self.probe(git)

    #expect(
      await probe.isOnFirstParentChain(
        tip: try Self.oid(tipHex), destination: try Self.oid(destinationHex)) == nil)
  }

  @Test("replace ref と grafts を無効にして rev-list を呼ぶ")
  func ignoresHistoryRewrites() async throws {
    let git = FirstParentGit(
      revList: .init(exitCode: 0, stdout: "\(destinationHex) \(tipHex)\n", stderr: ""))
    // 実行されるのは偽の `ProcessRunning` だけで、ここでは公開の init が要求する「実在する実行
    // ファイル」を満たすためだけに置く。
    let probe = try GitBranchMergeProbe(
      repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: git,
      mergeCache: GitBranchMergeCache(),
      executableCandidates: [URL(fileURLWithPath: "/bin/sh")])

    _ = await probe.isOnFirstParentChain(
      tip: try Self.oid(tipHex), destination: try Self.oid(destinationHex))

    let environments = await git.environments
    try #require(!environments.isEmpty)
    #expect(environments.allSatisfy { $0["GIT_NO_REPLACE_OBJECTS"] == "1" })
    #expect(environments.allSatisfy { $0["GIT_GRAFT_FILE"] != nil })
  }

  private static func oid(_ hex: String) throws -> CommitObjectID {
    try #require(CommitObjectID(hex))
  }

  private static func probe(_ git: FirstParentGit) throws -> GitBranchMergeProbe {
    GitBranchMergeProbe(
      runner: try GitRunner(
        repositoryDirectory: URL(fileURLWithPath: "/repo"), processRunner: git,
        executableCandidates: [URL(fileURLWithPath: "/test/bin/git")], parentEnvironment: [:],
        isExecutableFile: { _ in true }),
      mergeCache: GitBranchMergeCache())
  }
}

/// `rev-list` にだけ決めた結果を返し、ほかのコマンドは起動の失敗にする git。
private actor FirstParentGit: ProcessRunning {
  private let revList: ProcessRunResult
  private(set) var commands: [[String]] = []
  private(set) var environments: [[String: String]] = []

  init(revList: ProcessRunResult) {
    self.revList = revList
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    let command = commandArguments(arguments)
    commands.append(command)
    environments.append(environment)
    guard command.first == "rev-list" else {
      throw .launchFailed(executableURL: URL(fileURLWithPath: "/unexpected"), message: "")
    }
    return revList
  }
}
