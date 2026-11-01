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

/// Issue #502 の git 2.50.1 実測: lock した worktree の `.git` が消えると、`rev-parse` は祖先へ
/// 遡って exit 0 で祖先の git ディレクトリを返す。main でない entry の出力は
/// `<git-dir>\n<common>\n<bare>\n<prefix>\n` の4行で、prefix は作業ツリーの根なら空行になる。
@Suite("§3.2 main でない entry が祖先の git ディレクトリへ解決したら、検出せず失敗として返す")
struct GitWorktreeDetectorAncestorTests {
  @Test("main でない entry の prefix が空でなければ、祖先への解決として返す")
  func reportsNonEmptyPrefixAsAncestorResolution() async throws {
    let stub = ProcessRunnerStub { directory in
      guard directory == nestedWorktree else { return nil }
      return "\(commonDirectory)/worktrees/feat\n\(commonDirectory)\nfalse\n.worktrees/y/\n"
    }

    let result = try await makeDetector(stub).scan()

    #expect(result.detected.map(\.worktreePath) == [projectDirectory, parentWorktree])
    #expect(result.failures == [ancestorFailure(nestedWorktree)])
  }

  /// git ディレクトリと common dir が等しく、common dir が別 Project で、prefix も空 — 置き換わった
  /// entry (`.absent`) と同じ形なので、bare であることだけが区別の手掛かりになる。
  @Test("main でない entry が別の bare repository へ解決したら、除外せず祖先への解決として返す")
  func reportsBareRepositoryAsAncestorResolution() async throws {
    let stub = ProcessRunnerStub { directory in
      guard directory == nestedWorktree else { return nil }
      return "/other.git\n/other.git\ntrue\n\n"
    }

    let result = try await makeDetector(stub).scan()

    #expect(result.detected.map(\.worktreePath) == [projectDirectory, parentWorktree])
    #expect(result.failures == [ancestorFailure(nestedWorktree)])
  }

  @Test("main でない entry の git ディレクトリがこの Project の common dir なら、prefix が空でも返す")
  func reportsProjectCommonDirectoryAsAncestorResolution() async throws {
    let stub = ProcessRunnerStub { directory in
      guard directory == nestedWorktree else { return nil }
      return "\(commonDirectory)\n\(commonDirectory)\nfalse\n\n"
    }

    let result = try await makeDetector(stub).scan()

    #expect(result.detected.map(\.worktreePath) == [projectDirectory, parentWorktree])
    #expect(result.failures == [ancestorFailure(nestedWorktree)])
  }

  @Test("main の entry には bare と prefix を問い合わせない")
  func doesNotQueryBareOrPrefixForMainWorktree() async throws {
    let stub = ProcessRunnerStub { _ in nil }

    let result = try await makeDetector(stub).scan()

    #expect(result.failures.isEmpty)
    #expect(result.detected.map(\.isProjectRoot) == [true, false, false])
    #expect(await stub.prefixQueries == [parentWorktree, nestedWorktree])
  }

  @Test(
    "main でない entry の出力が4行でないか bare が真偽値でなければ、原文を捨てずに失敗として返す",
    arguments: [
      "\(commonDirectory)/worktrees/feat\n\(commonDirectory)\nfalse\n",
      "\(commonDirectory)/worktrees/feat\n\(commonDirectory)\nfalse\n\nextra\n",
      "\(commonDirectory)/worktrees/feat\n\(commonDirectory)\nfalse\nsub/",
      "\(commonDirectory)/worktrees/feat\n\(commonDirectory)\nmaybe\n\n",
    ]
  )
  func reportsUnexpectedLinkedWorktreeOutput(stdout: String) async throws {
    let stub = ProcessRunnerStub { directory in directory == parentWorktree ? stdout : nil }

    let result = try await makeDetector(stub).scan()

    #expect(result.detected.map(\.worktreePath) == [projectDirectory, nestedWorktree])
    #expect(
      result.failures == [
        GitWorktreeEntryFailure(
          worktreePath: parentWorktree, reason: .unexpectedGitDirectoryOutput(output: stdout))
      ])
  }

  private func ancestorFailure(_ worktreePath: String) -> GitWorktreeEntryFailure {
    GitWorktreeEntryFailure(worktreePath: worktreePath, reason: .resolvedToAncestorRepository)
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

/// `override` は作業ツリーごとの `rev-parse --git-dir …` の stdout を差し替える。`nil` には
/// 祖先へ遡っていない実挙動を返す: main は2行、linked は `<common>/worktrees/<名前>` と
/// `false` と空の prefix の4行。
private actor ProcessRunnerStub: ProcessRunning {
  private let override: @Sendable (String) -> String?
  private(set) var prefixQueries: [String] = []

  init(override: @escaping @Sendable (String) -> String?) {
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
    if arguments.contains("--show-prefix") { prefixQueries.append(directory) }
    return ProcessRunResult(exitCode: 0, stdout: stdout(arguments, directory), stderr: "")
  }

  private func stdout(_ arguments: [String], _ directory: String) -> String {
    if arguments.contains("worktree") { return listOutput }
    guard arguments.contains("--git-dir") else { return "\(commonDirectory)\n" }
    if let stdout = override(directory) { return stdout }
    guard directory != projectDirectory else { return "\(commonDirectory)\n\(commonDirectory)\n" }
    let name = URL(fileURLWithPath: directory).lastPathComponent
    return "\(commonDirectory)/worktrees/\(name)\n\(commonDirectory)\nfalse\n\n"
  }
}
