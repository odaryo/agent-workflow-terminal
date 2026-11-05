import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("Close の削除を妨げる条件の観測 (設計書 §3.4)")
struct GitWorktreeRemovalObstaclesReaderTests {
  private static let administrativeDirectory = "/repo/.git/worktrees/feature-a"

  @Test("lock は空の理由と改行を含む理由を保持し末尾の改行だけ除く", arguments: ["", "portable\nvolume\n"])
  func readsLockReason(contents: String) async throws {
    let result = try await removalInspection(
      existingFiles: [Self.administrativeDirectory + "/locked"], readFile: { _ in contents })
    let expected = contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
    #expect(
      result.report.removalObstacles == .observed(lockReason: expected, populatedSubmodules: []))
  }

  @Test("modules があれば gitlink の一覧が空でも submodule を含む")
  func detectsAdministrativeModules() async throws {
    let result = try await removalInspection(existingFiles: [
      Self.administrativeDirectory + "/modules"
    ])
    #expect(
      result.report.removalObstacles
        == .observed(lockReason: nil, populatedSubmodules: [], hasAdministrativeModules: true))
  }

  @Test("gitlink の .git があるときだけ submodule を妨げとする", arguments: [true, false])
  func detectsPopulatedGitlinks(populated: Bool) async throws {
    let path = try #require(WorktreeRelativePath("libs/sub"))
    let git = gitStub(
      index: .init(exitCode: 0, stdout: "160000 \(fixtureTipHex) 0\tlibs/sub\0", stderr: ""))
    let result = try await removalInspection(
      git: git, existingFiles: populated ? ["/repo/wt/libs/sub/.git"] : [])
    #expect(
      result.report.removalObstacles
        == .observed(lockReason: nil, populatedSubmodules: populated ? [path] : []))
  }

  @Test("ls-files は作業ツリーで実行し timeout と環境を固定する")
  func readsIndexInWorkingTree() async throws {
    let git = gitStub()
    _ = try await removalInspection(git: git)
    let invocation = try #require(await git.invocations.first { $0.arguments.contains("ls-files") })
    #expect(
      invocation.arguments == [
        "--no-optional-locks", "-C", "/repo/wt", "--no-pager", "ls-files", "--stage", "-z",
      ])
    expectFixedGitInvocation(invocation, timeout: .seconds(30))
  }

  @Test("ls-files の失敗は途中状態を巻き込まず削除の妨げだけ unknown にする")
  func reportsUnknownRemovalOnIndexFailure() async throws {
    let failure = ProcessRunResult(exitCode: 128, stdout: "", stderr: "fatal: index\n")
    let result = try await removalInspection(git: gitStub(index: failure))
    #expect(result.report.progress == .observed([]))
    #expect(result.report.removalObstacles == .unknown)
    #expect(
      result.removalObstaclesFailure
        == .git(.commandFailed(exitCode: 128, stdout: "", stderr: failure.stderr)))
  }

  @Test("在る locked を読めなければ削除の妨げは unknown")
  func reportsUnknownRemovalOnLockReadFailure() async throws {
    let path = Self.administrativeDirectory + "/locked"
    let result = try await removalInspection(
      existingFiles: [path], readFile: { _ in throw CocoaError(.fileReadNoPermission) })
    #expect(result.report.removalObstacles == .unknown)
    #expect(result.removalObstaclesFailure == .lockFileUnreadable(path: path))
    #expect(result.report.progress == .observed([]))
  }

  @Test("途中状態が読めなくても lock は独立に読む")
  func readsRemovalDespiteProgressFailure() async throws {
    let failure = ProcessRunResult(exitCode: 128, stdout: "", stderr: "fatal: ref\n")
    let result = try await removalInspection(
      git: gitStub(references: ["MERGE_HEAD": failure]),
      existingFiles: [Self.administrativeDirectory + "/locked"], readFile: { _ in "locked\n" })
    #expect(result.report.progress == .unknown)
    #expect(
      result.report.removalObstacles == .observed(lockReason: "locked", populatedSubmodules: []))
    #expect(result.failure != nil)
    #expect(result.removalObstaclesFailure == nil)
  }

  private func removalInspection(
    git: WorktreeCloseGitStub = gitStub(), existingFiles: Set<String> = [],
    readFile: @escaping @Sendable (String) throws -> String = { _ in "" }
  ) async throws -> GitWorktreeProgressInspectionResult {
    let target = try WorktreeCloseHarness.detected(identity: Self.administrativeDirectory)
    let worktreeRunner = try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: target.worktreePath), processRunner: git,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: pollutedParentEnvironment, isExecutableFile: { _ in true })
    return await GitWorktreeProgressInspector(
      target: target, runner: try runner(git: git), worktreeRunner: worktreeRunner,
      fileExists: { existingFiles.contains($0) }, readFile: readFile
    ).inspect()
  }

  private func runner(git: WorktreeCloseGitStub) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: Self.administrativeDirectory),
      processRunner: git, executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: [:], isExecutableFile: { _ in true })
  }
}
