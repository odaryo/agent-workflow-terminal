import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// patch の出力量は変更集合の大きさに比例する。計測: 220,000 行 (10.7 MB) のファイルを1つ
/// `git add` しただけで staged patch が 10,889,014 バイトになり、`GitRunner` の既定 8 MiB では
/// `outputLimitExceeded(limit: 8388608)` でその worktree の Diff が丸ごと開けなくなる。
///
/// 実 git で 8 MiB 超の patch を作るテストは、同じプロセスで並行に走る CPU 計測のテスト
/// (`FileChangeWatcherIntegrationTests.releasesPollingOnCancellation` 等) を巻き込んで
/// 落とすため、境界へ渡す上限そのものを固定する。
@Suite("§9.1.3 Diff 取得の出力上限")
struct DiffSnapshotBuilderOutputLimitTests {
  @Test("patch には既定ではなく diff 専用の上限を渡す")
  func passesDiffOutputLimit() async throws {
    let spy = OutputLimitSpy()
    let builder = try DiffSnapshotBuilder(
      worktreeRoot: URL(fileURLWithPath: "/repo"),
      processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")])
    _ = try await builder.build(
      .base(branch: "main"), id: DiffSnapshotID(rawValue: UUID()), now: Date())

    let calls = await spy.calls
    let patchLimits = calls.filter { $0.arguments.contains("--patch") }.map(\.outputLimit)
    #expect(patchLimits.count == 3)
    #expect(patchLimits.allSatisfy { $0 == GitRunner.diffPatchOutputLimit })
    #expect(GitRunner.diffPatchOutputLimit > GitRunner.defaultOutputLimit)
    // patch 以外は既定のままにする。上限を上げる理由は patch の出力量にしかない。
    #expect(
      calls.filter { !$0.arguments.contains("--patch") }
        .allSatisfy { $0.outputLimit == GitRunner.defaultOutputLimit })
  }

  @Test("Commit Diff の patch にも同じ上限を渡す")
  func passesDiffOutputLimitForCommitDiff() async throws {
    let spy = OutputLimitSpy()
    let builder = try DiffSnapshotBuilder(
      worktreeRoot: URL(fileURLWithPath: "/repo"),
      processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")])
    _ = try await builder.build(
      .commit(
        hash: String(repeating: "b", count: 40), parentHashes: [String(repeating: "c", count: 40)]),
      id: DiffSnapshotID(rawValue: UUID()), now: Date())

    let calls = await spy.calls
    let patchLimits = calls.filter { $0.arguments.contains("--patch") }.map(\.outputLimit)
    #expect(patchLimits == [GitRunner.diffPatchOutputLimit])
  }

  @Test("親を持たない commit の patch にも同じ上限を渡す")
  func passesDiffOutputLimitForRootCommit() async throws {
    let spy = OutputLimitSpy()
    let builder = try DiffSnapshotBuilder(
      worktreeRoot: URL(fileURLWithPath: "/repo"),
      processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")])
    _ = try await builder.build(
      .commit(hash: String(repeating: "b", count: 40), parentHashes: []),
      id: DiffSnapshotID(rawValue: UUID()), now: Date())

    let calls = await spy.calls
    #expect(calls.contains { $0.arguments.contains("hash-object") })
    #expect(
      calls.filter { $0.arguments.contains("--patch") }.map(\.outputLimit)
        == [GitRunner.diffPatchOutputLimit])
  }
}

private actor OutputLimitSpy: ProcessRunning {
  struct Call: Sendable {
    let arguments: [String]
    let outputLimit: Int
  }
  private(set) var calls: [Call] = []

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(Call(arguments: arguments, outputLimit: outputLimit))
    // merge-base と空 tree の出力だけは range を組める OID である必要がある。
    let needsObjectID = arguments.contains("merge-base") || arguments.contains("hash-object")
    let stdout = needsObjectID ? String(repeating: "a", count: 40) + "\n" : ""
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }
}
