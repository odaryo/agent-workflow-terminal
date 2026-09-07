import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§7.1 Git status の File Browser 状態変換")
struct GitStatusWorktreeStateTests {
  @Test(
    "git の8つの状態コードを1対1で変換する",
    arguments: [
      (GitFileStatusCode.unchanged, WorktreeGitFileStatus.unchanged),
      (.modified, .modified),
      (.typeChanged, .typeChanged),
      (.added, .added),
      (.deleted, .deleted),
      (.renamed, .renamed),
      (.copied, .copied),
      (.unmerged, .unmerged),
    ])
  func convertsEveryStatusCode(_ code: GitFileStatusCode, _ expected: WorktreeGitFileStatus) {
    #expect(code.worktreeStatus == expected)
  }

  @Test("1パスに付く index と worktree の2軸を潰さない")
  func keepsBothAxes() {
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

  @Test("index の gitlink 行だけをサブモジュールとして取り出す")
  func parsesGitlinkRowsOnly() {
    let parsed = GitIndexSubmodules.parse(
      output:
        "100644 1bd30cc0000000000000000000000000000000ab 0\t.gitmodules\0"
        + "160000 721194b0000000000000000000000000000000cd 0\tsub\0"
        + "100644 721194b0000000000000000000000000000000ef 0\tp.txt\0"
        + "160000 721194b00000000000000000000000000000ab12 0\t../escape\0")

    #expect(parsed.entries == [.submodule(path: path("sub"))])
    #expect(parsed.failures == [.invalidPath("../escape")])
  }

  @Test("状態取得は status と index の両方を読み、失敗を保持する")
  func readsStatusAndIndex() async throws {
    let spy = WorktreeStatusProcessSpy(
      statusOutput: "x unknown\0? generated/\0! ../invalid\0",
      listFilesOutput: "160000 721194b0000000000000000000000000000000cd 0\tsub\0")
    let runner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: "/repo"),
      processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/git")],
      parentEnvironment: [:],
      isExecutableFile: { _ in true })

    let result = try await WorktreeGitStateReader(runner: runner).read()

    #expect(await spy.invocations.contains { $0.contains("--ignored=matching") })
    #expect(await spy.invocations.contains { $0.contains("ls-files") && $0.contains("--stage") })
    #expect(
      result.entries == [
        .untracked(path: path("generated"), scope: .directory),
        .submodule(path: path("sub")),
      ])
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
  private(set) var invocations: [[String]] = []
  let statusOutput: String
  let listFilesOutput: String

  init(statusOutput: String, listFilesOutput: String) {
    self.statusOutput = statusOutput
    self.listFilesOutput = listFilesOutput
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    return ProcessRunResult(
      exitCode: 0,
      stdout: arguments.contains("ls-files") ? listFilesOutput : statusOutput,
      stderr: "")
  }
}
