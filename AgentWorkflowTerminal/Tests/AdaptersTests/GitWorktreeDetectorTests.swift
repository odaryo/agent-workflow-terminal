import Foundation
import TerminalCore
import Testing

@testable import Adapters

private let projectDirectory = "/repo"
private let commonDirectory = "/repo/.git"

@Suite("§3.2 worktree 検出が git へ渡す引数と、部分結果を返さないこと")
struct GitWorktreeDetectorTests {

  // MARK: - 実出力からの検出

  @Test("実際の worktree list 出力から DetectedWorktree を作る")
  func detectsWorktreesFromFixture() async throws {
    let listOutput = try fixture(named: "git-2.50.1-worktree-list-porcelain-z.txt")
    let paths = GitWorktreeList.parse(output: listOutput).entries.map(\.path)
    let mainWorktree = try #require(paths.first)
    let stub = ProcessRunnerStub { arguments in
      guard let directory = repositoryDirectory(of: arguments) else { return .failure(.cancelled) }
      if directory == projectDirectory { return success(listOutput) }
      // main worktree では2行が等しくなる (git 2.50.1 実測)。
      if directory == mainWorktree { return success(gitDirectories(commonDirectory)) }
      return success(gitDirectories(linkedGitDirectory(of: directory)))
    }

    let detected = try await makeDetector(stub).scan()

    #expect(detected.count == 4)
    #expect(detected.map(\.worktreePath) == paths)
    #expect(detected.map(\.isProjectRoot) == [true, false, false, false])
    #expect(detected.map(\.branch) == ["main", "feat/wt1", nil, "feat/日本語🚀"])
    #expect(detected[0].identity.rawValue == commonDirectory)
    #expect(detected[3].identity.rawValue == "\(commonDirectory)/worktrees/wt3-日本語🚀")
  }

  @Test("一覧は project root で、安定 ID は各作業ツリーで問い合わせる")
  func queriesEachWorktreeForItsGitDirectory() async throws {
    let stub = ProcessRunnerStub(handler: listThenGitDirectories(singleWorktreeList))

    _ = try await makeDetector(stub).scan()

    let invocations = await stub.invocations
    #expect(invocations.count == 2)
    #expect(
      invocations.first
        == [
          "--no-optional-locks", "-C", projectDirectory, "--no-pager",
          "worktree", "list", "--porcelain", "-z",
        ])
    #expect(
      invocations.last
        == [
          "--no-optional-locks", "-C", "/wt/alpha", "--no-pager",
          "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
        ])
  }

  // MARK: - 除外

  @Test("prunable な entry は検出結果に含めず、安定 ID も問い合わせない")
  func skipsPrunableEntries() async throws {
    let listOutput =
      singleWorktreeList
      + "worktree /wt/gone\0detached\0prunable gitdir file points to non-existent location\0\0"
    let stub = ProcessRunnerStub(handler: listThenGitDirectories(listOutput))

    let detected = try await makeDetector(stub).scan()

    #expect(detected.map(\.worktreePath) == ["/wt/alpha"])
    #expect(await stub.invocations.allSatisfy { !$0.contains("/wt/gone") })
  }

  @Test("bare な entry は検出結果に含めない")
  func skipsBareEntries() async throws {
    let listOutput = "worktree /srv/myrepo.git\0bare\0\0" + singleWorktreeList
    let stub = ProcessRunnerStub(handler: listThenGitDirectories(listOutput))

    let detected = try await makeDetector(stub).scan()

    #expect(detected.map(\.worktreePath) == ["/wt/alpha"])
    #expect(await stub.invocations.allSatisfy { !$0.contains("/srv/myrepo.git") })
  }

  // MARK: - 部分結果を返さない

  @Test("壊れた record が1件でもあればスキャン全体を失敗させ、安定 ID を問い合わせない")
  func failsEntireScanOnMalformedRecord() async throws {
    let stub = ProcessRunnerStub(
      handler: listThenGitDirectories(singleWorktreeList + "HEAD abcdef\0\0"))

    await #expect(
      throws: GitWorktreeScanError.malformedListOutput([
        GitWorktreeParseFailure(recordNumber: 2, record: "HEAD abcdef", error: .missingWorktree)
      ])
    ) {
      try await makeDetector(stub).scan()
    }
    #expect(await stub.invocations.count == 1)
  }

  @Test("prunable でない entry の rev-parse が失敗したら、残りを返さずスキャン全体を失敗させる")
  func failsEntireScanWhenGitDirectoryLookupFails() async throws {
    let listOutput = singleWorktreeList + "worktree /wt/beta\0branch refs/heads/beta\0\0"
    let failure = ProcessRunResult(
      exitCode: 128,
      stdout: "",
      stderr: "fatal: cannot change to '/wt/beta': No such file or directory\n"
    )
    let stub = ProcessRunnerStub { arguments in
      guard let directory = repositoryDirectory(of: arguments) else { return .failure(.cancelled) }
      if directory == projectDirectory { return success(listOutput) }
      if directory == "/wt/beta" { return .success(failure) }
      return success(gitDirectories(linkedGitDirectory(of: directory)))
    }

    await #expect(
      throws: GitWorktreeScanError.gitDirectory(
        worktreePath: "/wt/beta",
        .commandFailed(exitCode: 128, stdout: failure.stdout, stderr: failure.stderr))
    ) {
      try await makeDetector(stub).scan()
    }
  }

  @Test("一覧の取得自体が失敗したら安定 ID を問い合わせない")
  func failsWhenListingFails() async throws {
    let stub = ProcessRunnerStub { _ in
      .success(.init(exitCode: 128, stdout: "", stderr: "fatal: not a git repository\n"))
    }

    await #expect(
      throws: GitWorktreeScanError.list(
        .commandFailed(exitCode: 128, stdout: "", stderr: "fatal: not a git repository\n"))
    ) {
      try await makeDetector(stub).scan()
    }
    #expect(await stub.invocations.count == 1)
  }

  @Test(
    "rev-parse の出力が2行でなければ原文を捨てずに失敗させる",
    arguments: ["", "/repo/.git\n", "/repo/.git\n/repo/.git\n/extra\n"]
  )
  func rejectsUnexpectedGitDirectoryOutput(stdout: String) async throws {
    let stub = ProcessRunnerStub(handler: listThenFixedGitDirectoryOutput(stdout))

    await #expect(
      throws: GitWorktreeScanError.unexpectedGitDirectoryOutput(
        worktreePath: "/wt/alpha", output: stdout)
    ) {
      try await makeDetector(stub).scan()
    }
  }

  @Test("絶対パスでない git ディレクトリを安定 ID にしない")
  func rejectsRelativeGitDirectory() async throws {
    let stub = ProcessRunnerStub(
      handler: listThenFixedGitDirectoryOutput(".git/worktrees/alpha\n.git\n"))

    await #expect(
      throws: GitWorktreeScanError.invalidGitDirectoryPath(
        worktreePath: "/wt/alpha", gitDirectory: ".git/worktrees/alpha")
    ) {
      try await makeDetector(stub).scan()
    }
  }

  // MARK: - branch の短縮

  @Test(
    "branch は refs/heads/ を落とし、detached は nil にする",
    arguments: [
      ("branch refs/heads/main", "main"),
      ("branch refs/heads/feat/a/b", "feat/a/b"),
      ("branch refs/tags/v1", "refs/tags/v1"),
      ("detached", nil),
    ]
  )
  func shortensBranchNames(attribute: String, expected: String?) async throws {
    let stub = ProcessRunnerStub(
      handler: listThenGitDirectories("worktree /wt/alpha\0\(attribute)\0\0"))

    let detected = try await makeDetector(stub).scan()

    #expect(detected.map(\.branch) == [expected])
  }

  // MARK: - Helpers

  private func makeDetector(_ stub: ProcessRunnerStub) throws -> GitWorktreeDetector {
    GitWorktreeDetector(
      projectRunner: try testGitRunner(directory: projectDirectory, processRunner: stub),
      makeRunner: { directory throws(GitRunnerError) in
        try testGitRunner(directory: directory.path, processRunner: stub)
      }
    )
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}

// MARK: - テストダブル

private let singleWorktreeList = "worktree /wt/alpha\0branch refs/heads/alpha\0\0"

private typealias StubResult = Result<ProcessRunResult, ProcessRunnerError>
private typealias StubHandler = @Sendable ([String]) -> StubResult

/// `worktree list` には与えた出力を、`rev-parse` には `<common>/worktrees/<作業ツリー名>` を返す。
private func listThenGitDirectories(_ listOutput: String) -> StubHandler {
  { arguments in
    guard let directory = repositoryDirectory(of: arguments) else { return .failure(.cancelled) }
    if directory == projectDirectory { return success(listOutput) }
    return success(gitDirectories(linkedGitDirectory(of: directory)))
  }
}

/// `rev-parse` の出力だけを差し替えて、解釈できない出力の扱いを見るためのハンドラ。
private func listThenFixedGitDirectoryOutput(_ stdout: String) -> StubHandler {
  { arguments in
    guard let directory = repositoryDirectory(of: arguments) else { return .failure(.cancelled) }
    if directory == projectDirectory { return success(singleWorktreeList) }
    return success(stdout)
  }
}

private func linkedGitDirectory(of worktreePath: String) -> String {
  "\(commonDirectory)/worktrees/\(URL(fileURLWithPath: worktreePath).lastPathComponent)"
}

/// `rev-parse --git-dir --git-common-dir` の2行出力。
private func gitDirectories(_ gitDirectory: String) -> String {
  "\(gitDirectory)\n\(commonDirectory)\n"
}

private func success(_ stdout: String) -> StubResult {
  .success(.init(exitCode: 0, stdout: stdout, stderr: ""))
}

/// `GitRunner` が前置する `-C <dir>` から、その実行がどの作業ツリーに対するものかを取り出す。
private func repositoryDirectory(of arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: "-C"), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
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

private actor ProcessRunnerStub: ProcessRunning {
  private let handler: StubHandler
  private(set) var invocations: [[String]] = []

  init(handler: @escaping StubHandler) {
    self.handler = handler
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    return try handler(arguments).get()
  }
}
