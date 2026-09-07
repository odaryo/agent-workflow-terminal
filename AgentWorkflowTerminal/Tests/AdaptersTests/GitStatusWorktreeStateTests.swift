import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§7.1 Git status の File Browser 状態変換")
struct GitStatusWorktreeStateTests {
  @Test("git の8状態と index／worktree の2軸を損失なく変換する")
  func convertsEveryStatusCode() {
    let statuses: [GitFileStatusCode] = [
      .unchanged, .modified, .typeChanged, .added, .deleted, .renamed, .copied, .unmerged,
    ]
    #expect(statuses.compactMap(\.worktreeStatus).count == statuses.count)

    let parsed = GitStatusPorcelainV2.parse(
      output:
        "1 .T N... 100644 100644 120000 a b f.txt\0"
        + "1 AD N... 000000 100644 000000 0 c new.txt\0")
    let converted = parsed.status.worktreeStateEntries()
    #expect(converted.failures.isEmpty)
    #expect(converted.entries.count == 2)
    guard
      case .changed(_, let typeIndex, let typeWorktree) = converted.entries.first,
      case .changed(_, let addedIndex, let deletedWorktree) = converted.entries.last
    else {
      Issue.record("changed entry に変換されなかった")
      return
    }
    #expect(typeIndex == .unchanged)
    #expect(typeWorktree == .typeChanged)
    #expect(addedIndex == .added)
    #expect(deletedWorktree == .deleted)
  }

  @Test("git 2.50.1 fixture の rename 後パスを変換する")
  func convertsMeasuredFixture() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "git-2.50.1-status-porcelain-v2-branch-z.txt",
        withExtension: nil,
        subdirectory: "Fixtures"))
    let parsed = GitStatusPorcelainV2.parse(
      output: String(decoding: try Data(contentsOf: url), as: UTF8.self))

    let converted = parsed.status.worktreeStateEntries()

    #expect(converted.failures.isEmpty)
    #expect(
      converted.entries.contains(
        .changed(
          path: path("newname.txt"), indexStatus: .renamed, worktreeStatus: .modified)))
  }

  @Test("unmerged と末尾スラッシュの scope を変換する")
  func convertsUnmergedAndPathScopes() {
    let parsed = GitStatusPorcelainV2.parse(
      output:
        "u UU N... 100644 100644 100644 100644 a b c conflict.txt\0"
        + "? generated/\0! cache/\0? loose.txt\0")
    let converted = parsed.status.worktreeStateEntries()

    #expect(converted.failures.isEmpty)
    #expect(converted.entries.count == 4)
    guard case .unmerged(_, let index, let worktree) = converted.entries[0] else {
      Issue.record("unmerged entry に変換されなかった")
      return
    }
    #expect(index == .unmerged)
    #expect(worktree == .unmerged)
    #expect(converted.entries[1] == .untracked(path: path("generated"), scope: .directory))
    #expect(converted.entries[2] == .ignored(path: path("cache"), scope: .directory))
    #expect(converted.entries[3] == .untracked(path: path("loose.txt"), scope: .exact))
  }

  @Test("不正パスを黙って捨てず部分失敗として返す")
  func reportsInvalidPaths() {
    let parsed = GitStatusPorcelainV2.parse(output: "? ../outside\0! ok\0")
    let converted = parsed.status.worktreeStateEntries()

    #expect(converted.entries == [.ignored(path: path("ok"), scope: .exact)])
    #expect(converted.failures == [.invalidPath("../outside")])
  }

  @Test("状態取得は ignored=matching を指定し、パース失敗と変換失敗を保持する")
  func readsStatusIncludingIgnored() async throws {
    let spy = WorktreeStatusProcessSpy(
      output: "x unknown\0? generated/\0! ../invalid\0")
    let runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"),
      processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/git")],
      parentEnvironment: [:],
      isExecutableFile: { _ in true })

    let result = try await WorktreeGitStateReader(runner: runner).read()

    #expect(await spy.arguments.last == "--ignored=matching")
    #expect(result.entries == [.untracked(path: path("generated"), scope: .directory)])
    #expect(result.statusParseFailures.count == 1)
    #expect(result.conversionFailures == [.invalidPath("../invalid")])
  }

  private func path(_ value: String) -> WorktreeRelativePath {
    guard let path = WorktreeRelativePath(value) else {
      preconditionFailure("テスト fixture のパスが不正: \(value)")
    }
    return path
  }
}

private actor WorktreeStatusProcessSpy: ProcessRunning {
  private(set) var arguments: [String] = []
  let output: String

  init(output: String) { self.output = output }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    self.arguments = arguments
    return ProcessRunResult(exitCode: 0, stdout: output, stderr: "")
  }
}
