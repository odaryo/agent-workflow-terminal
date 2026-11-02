import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("同じ安定 ID の組の本物判定に注入した finder を使う (Issue #531)")
struct GitWorktreeSharedIdentityFinderTests {
  @Test("finder が組の ID を返す entry だけを残し、先に並ぶ偽物を失敗にする")
  func retainsOnlyEntryIdentifiedByInjectedFinder() async throws {
    let root = "/awt-shared-identity-\(UUID().uuidString)"
    let commonPath = "\(root)/main/.git"
    let sharedPath = "\(commonPath)/worktrees/feat"
    let genuinePath = "\(root)/feat"
    let duplicatePath = "\(root)/dup"
    let commonIdentity = try #require(WorktreeIdentity(rawValue: commonPath))
    let sharedIdentity = try #require(WorktreeIdentity(rawValue: sharedPath))
    let stub = SharedIdentityProcessRunnerStub(
      mainPath: "\(root)/main", commonPath: commonPath, sharedPath: sharedPath,
      linkedPaths: [duplicatePath, genuinePath])
    let detector = GitWorktreeDetector(
      projectRunner: try makeRunner(directory: URL(fileURLWithPath: "\(root)/main"), stub: stub),
      makeRunner: { directory throws(GitRunnerError) in
        try makeRunner(directory: directory, stub: stub)
      },
      isWorktreeReachable: { _ in true },
      findAdministrativeDirectory: { path, commonDirectory in
        path == genuinePath && commonDirectory == commonIdentity ? sharedIdentity : nil
      }
    )

    let result = try await detector.scan()

    #expect(result.detected.map(\.worktreePath) == ["\(root)/main", genuinePath])
    #expect(result.detected.map(\.identity) == [commonIdentity, sharedIdentity])
    #expect(result.detected.map(\.isReachable) == [true, true])
    #expect(result.detected.map(\.isProjectRoot) == [true, false])
    #expect(
      result.failures == [
        GitWorktreeEntryFailure(
          worktreePath: duplicatePath, reason: .sharedIdentity(gitDirectory: sharedPath))
      ])
  }
}

private func makeRunner(
  directory: URL, stub: SharedIdentityProcessRunnerStub
) throws(GitRunnerError) -> GitRunner {
  try GitRunner(
    repositoryDirectory: directory,
    processRunner: stub,
    executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
    parentEnvironment: [:],
    isExecutableFile: { _ in true }
  )
}

private struct SharedIdentityProcessRunnerStub: ProcessRunning {
  let mainPath: String
  let commonPath: String
  let sharedPath: String
  let linkedPaths: [String]

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    let stdout: String
    if arguments.contains("worktree") {
      stdout = ([mainPath] + linkedPaths).map { "worktree \($0)\0detached\0\0" }.joined()
    } else if !arguments.contains("--git-dir") {
      stdout = "\(commonPath)\n"
    } else if arguments.contains("--show-prefix") {
      stdout = "\(sharedPath)\n\(commonPath)\nfalse\n\n"
    } else {
      stdout = "\(commonPath)\n\(commonPath)\n"
    }
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }
}
