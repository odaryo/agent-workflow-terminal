import Foundation
import TerminalCore
import Testing

@testable import Adapters

private let projectDirectory = "/repo"
private let commonDirectory = "/repo/.git"
private let parentWorktree = "/wt/feat"
private let nestedWorktree = "/wt/feat/.worktrees/y"

private let listOutput =
  "worktree \(projectDirectory)\0branch refs/heads/main\0\0"
  + "worktree \(parentWorktree)\0branch refs/heads/feat\0\0"
  + "worktree \(nestedWorktree)\0branch refs/heads/y\0locked\0\0"

private let toplevelFailure = ProcessRunResult(
  exitCode: 128, stdout: "", stderr: "fatal: this operation must be run in a work tree\n")

/// Issue #502 の git 2.50.1 実測: lock した worktree の `.git` が消えると、`rev-parse` は祖先へ
/// 遡って exit 0 で祖先の git ディレクトリを返す。
@Suite("§3.2 main でない entry が祖先の git ディレクトリへ解決したら、検出せず失敗として返す")
struct GitWorktreeDetectorAncestorTests {
  @Test("main でない entry の toplevel が entry 自身でなければ、祖先への解決として返す")
  func reportsToplevelMismatchAsAncestorResolution() async throws {
    let stub = ProcessRunnerStub { arguments, directory in
      guard directory == nestedWorktree else { return nil }
      if arguments.contains("--show-toplevel") { return success("\(parentWorktree)\n") }
      return success("\(commonDirectory)/worktrees/feat\n\(commonDirectory)\n")
    }

    let result = try await makeDetector(stub).scan()

    #expect(result.detected.map(\.worktreePath) == [projectDirectory, parentWorktree])
    #expect(
      result.failures == [
        GitWorktreeEntryFailure(worktreePath: nestedWorktree, reason: .resolvedToAncestorRepository)
      ])
    #expect(await stub.toplevelQueries == [parentWorktree, nestedWorktree])
  }

  /// linked worktree には必ず作業ツリーがあるので、toplevel の失敗は「確かめられなかった」である。
  @Test("main でない entry の toplevel を引けなければ、黙って落とさず gitDirectory の失敗として返す")
  func reportsToplevelFailureAsGitDirectoryFailure() async throws {
    let stub = ProcessRunnerStub { arguments, directory in
      guard directory == parentWorktree, arguments.contains("--show-toplevel") else { return nil }
      return .success(toplevelFailure)
    }

    let result = try await makeDetector(stub).scan()

    #expect(result.detected.map(\.worktreePath) == [projectDirectory, nestedWorktree])
    #expect(
      result.failures == [
        GitWorktreeEntryFailure(
          worktreePath: parentWorktree,
          reason: .gitDirectory(
            .commandFailed(exitCode: 128, stdout: "", stderr: toplevelFailure.stderr)))
      ])
  }

  /// 遡った先が bare だと `--show-toplevel` は exit 128 になる (git 2.50.1 実測) ので、git
  /// ディレクトリだけで判定できる場合は撃たない。
  @Test("main でない entry の git ディレクトリが common dir そのものなら、toplevel を引かずに返す")
  func reportsCommonDirectoryAsAncestorResolutionWithoutToplevel() async throws {
    let stub = ProcessRunnerStub { arguments, directory in
      guard directory == nestedWorktree, arguments.contains("--git-dir") else { return nil }
      return success("\(commonDirectory)\n\(commonDirectory)\n")
    }

    let result = try await makeDetector(stub).scan()

    #expect(result.detected.map(\.worktreePath) == [projectDirectory, parentWorktree])
    #expect(
      result.failures == [
        GitWorktreeEntryFailure(worktreePath: nestedWorktree, reason: .resolvedToAncestorRepository)
      ])
    #expect(await stub.toplevelQueries == [parentWorktree])
  }

  private func makeDetector(_ stub: ProcessRunnerStub) throws -> GitWorktreeDetector {
    GitWorktreeDetector(
      projectRunner: try testGitRunner(directory: projectDirectory, processRunner: stub),
      makeRunner: { directory throws(GitRunnerError) in
        try testGitRunner(directory: directory.path, processRunner: stub)
      },
      isWorktreeReachable: { _ in true },
      findAdministrativeDirectory: { _, _ in nil }
    )
  }
}

// MARK: - テストダブル

private typealias StubResult = Result<ProcessRunResult, ProcessRunnerError>

private func success(_ stdout: String) -> StubResult {
  .success(.init(exitCode: 0, stdout: stdout, stderr: ""))
}

private func testGitRunner(
  directory: String,
  processRunner: any ProcessRunning
) throws(GitRunnerError) -> GitRunner {
  try GitRunner(
    repositoryDirectory: URL(fileURLWithPath: directory),
    processRunner: processRunner,
    executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
    parentEnvironment: [:],
    isExecutableFile: { _ in true }
  )
}

/// `override` が `nil` を返した問い合わせには、祖先へ遡っていない実挙動を返す: linked worktree
/// の git ディレクトリは `<common>/worktrees/<名前>`、toplevel は作業ツリー自身。
private actor ProcessRunnerStub: ProcessRunning {
  private let override: @Sendable ([String], String) -> StubResult?
  private(set) var toplevelQueries: [String] = []

  init(override: @escaping @Sendable ([String], String) -> StubResult?) {
    self.override = override
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    guard let index = arguments.firstIndex(of: "-C"), index + 1 < arguments.count else {
      throw .cancelled
    }
    let directory = arguments[index + 1]
    if arguments.contains("--show-toplevel") { toplevelQueries.append(directory) }
    return try (override(arguments, directory) ?? defaultResult(arguments, directory)).get()
  }

  private func defaultResult(_ arguments: [String], _ directory: String) -> StubResult {
    if arguments.contains("worktree") { return success(listOutput) }
    if arguments.contains("--show-toplevel") { return success("\(directory)\n") }
    guard arguments.contains("--git-dir") else { return success("\(commonDirectory)\n") }
    guard directory != projectDirectory else {
      return success("\(commonDirectory)\n\(commonDirectory)\n")
    }
    let name = URL(fileURLWithPath: directory).lastPathComponent
    return success("\(commonDirectory)/worktrees/\(name)\n\(commonDirectory)\n")
  }
}
