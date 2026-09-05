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
    let stub = ProcessRunnerStub(handler: fixtureHandler(listOutput))

    let detected = try await makeDetector(stub).scan()

    #expect(detected.count == 4)
    #expect(detected.map(\.worktreePath) == paths)
    #expect(detected.map(\.isProjectRoot) == [true, false, false, false])
    #expect(detected.map(\.branch) == ["main", "feat/wt1", nil, "feat/日本語🚀"])
    #expect(detected[0].identity.rawValue == commonDirectory)
    #expect(detected[2].identity.rawValue == "\(commonDirectory)/worktrees/wt2-with-space")
    #expect(detected[3].identity.rawValue == "\(commonDirectory)/worktrees/wt3-日本語🚀")
  }

  @Test("一覧と Project の common dir は project root で、安定 ID は各作業ツリーで問い合わせる")
  func queriesEachWorktreeForItsGitDirectory() async throws {
    let stub = ProcessRunnerStub(handler: listThenGitDirectories(singleWorktreeList))

    _ = try await makeDetector(stub).scan()

    #expect(
      await stub.invocations == [
        [
          "--no-optional-locks", "-C", projectDirectory, "--no-pager",
          "worktree", "list", "--porcelain", "-z",
        ],
        [
          "--no-optional-locks", "-C", projectDirectory, "--no-pager",
          "rev-parse", "--path-format=absolute", "--git-common-dir",
        ],
        [
          "--no-optional-locks", "-C", "/wt/alpha", "--no-pager",
          "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
        ],
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
    let bareOutput = try fixture(named: "git-2.50.1-worktree-list-porcelain-z-bare.txt")
    let barePath = try #require(GitWorktreeList.parse(output: bareOutput).entries.first?.path)
    let stub = ProcessRunnerStub(handler: listThenGitDirectories(bareOutput + singleWorktreeList))

    let detected = try await makeDetector(stub).scan()

    #expect(detected.map(\.worktreePath) == ["/wt/alpha"])
    #expect(await stub.invocations.allSatisfy { !$0.contains(barePath) })
  }

  /// `locked` が付いた worktree には、作業ツリーが消えても `prunable` が付かない (git 2.50.1
  /// 実測)。失敗させると Project Root を含む全 worktree の検出が止まる。
  @Test("到達できない作業ツリーの entry は、スキャンを失敗させずに除外する")
  func skipsUnreachableWorkingTreeWithoutFailingTheScan() async throws {
    let listOutput = singleWorktreeList + "worktree /wt/locked\0branch refs/heads/locked\0\0"
    let stub = ProcessRunnerStub(
      handler: listThenGitDirectories(listOutput, failingIn: "/wt/locked"))

    let detected = try await makeDetector(stub, unreachable: ["/wt/locked"]).scan()

    #expect(detected.map(\.worktreePath) == ["/wt/alpha"])
  }

  /// 置き換わった先の repository でも `rev-parse` は exit 0 で、その repository の git
  /// ディレクトリを返す (git 2.50.1 実測)。common dir を見ないと Project Root が2件になる。
  @Test("別 repository に置き換わった entry は除外し、2つめの Project Root にしない")
  func skipsEntriesFromAnotherRepository() async throws {
    let listOutput = singleWorktreeList + "worktree /wt/foreign\0branch refs/heads/other\0\0"
    // /wt/alpha は main worktree、/wt/foreign は別 repository に置き換わった entry。
    let stub = ProcessRunnerStub(
      handler: stubHandler(listOutput: listOutput) { directory in
        directory == "/wt/foreign"
          ? success("/wt/foreign/.git\n/wt/foreign/.git\n")
          : success(gitDirectoryLines(commonDirectory))
      })

    let detected = try await makeDetector(stub).scan()

    #expect(detected.map(\.worktreePath) == ["/wt/alpha"])
    #expect(detected.map(\.isProjectRoot) == [true])
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

  /// 作業ツリーへ到達できるのに答えられないのは git ディレクトリ側の破損である (git 2.50.1
  /// 実測: 管理ディレクトリの `commondir` を消すと `not a git repository`)。除外へ回さない。
  @Test("到達できる作業ツリーの rev-parse が失敗したら、残りを返さずスキャン全体を失敗させる")
  func failsEntireScanWhenGitDirectoryLookupFails() async throws {
    let listOutput = singleWorktreeList + "worktree /wt/beta\0branch refs/heads/beta\0\0"
    let stub = ProcessRunnerStub(handler: listThenGitDirectories(listOutput, failingIn: "/wt/beta"))

    await #expect(
      throws: GitWorktreeScanError.gitDirectory(
        worktreePath: "/wt/beta",
        .commandFailed(exitCode: 128, stdout: "", stderr: revParseFailure.stderr))
    ) {
      try await makeDetector(stub).scan()
    }
  }

  @Test("git を起動できなかった entry は、作業ツリーの到達可能性で除外に振り替えない")
  func classifiesRunnerConstructionFailureSeparately() async throws {
    let stub = ProcessRunnerStub(handler: listThenGitDirectories(singleWorktreeList))
    let detector = GitWorktreeDetector(
      projectRunner: try testGitRunner(directory: projectDirectory, processRunner: stub),
      makeRunner: { _ throws(GitRunnerError) in throw .binaryNotFound(candidates: []) },
      isWorktreeReachable: { _ in false }
    )

    await #expect(
      throws: GitWorktreeScanError.gitRunnerUnavailable(
        worktreePath: "/wt/alpha", .binaryNotFound(candidates: []))
    ) {
      try await detector.scan()
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

  @Test("Project の common dir を引けなければ、entry を1件も問い合わせずに失敗させる")
  func failsWhenProjectCommonDirectoryLookupFails() async throws {
    let stub = ProcessRunnerStub { arguments in
      arguments.contains("worktree") ? success(singleWorktreeList) : .success(revParseFailure)
    }

    await #expect(
      throws: GitWorktreeScanError.projectCommonDirectory(
        .commandFailed(exitCode: 128, stdout: "", stderr: revParseFailure.stderr))
    ) {
      try await makeDetector(stub).scan()
    }
    #expect(await stub.invocations.count == 2)
  }

  @Test(
    "Project の common dir が絶対パス1行でなければ原文を捨てずに失敗させる",
    arguments: ["", ".git\n", "/repo/.git\n/repo/.git\n"]
  )
  func rejectsUnexpectedProjectCommonDirectoryOutput(stdout: String) async throws {
    let stub = ProcessRunnerStub { arguments in
      arguments.contains("worktree") ? success(singleWorktreeList) : success(stdout)
    }

    await #expect(
      throws: GitWorktreeScanError.unexpectedProjectCommonDirectoryOutput(output: stdout)
    ) {
      try await makeDetector(stub).scan()
    }
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

  @Test(
    "絶対パスでない git ディレクトリを安定 ID にも判定基準にもしない",
    arguments: [
      (".git/worktrees/alpha\n/repo/.git\n", ".git/worktrees/alpha"),
      ("/repo/.git/worktrees/alpha\n.git\n", ".git"),
    ]
  )
  func rejectsRelativeGitDirectory(stdout: String, rejected: String) async throws {
    let stub = ProcessRunnerStub(handler: listThenFixedGitDirectoryOutput(stdout))

    await #expect(
      throws: GitWorktreeScanError.invalidGitDirectoryPath(
        worktreePath: "/wt/alpha", gitDirectory: rejected)
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

  /// 既定で全 entry を到達可能として扱い、単体テストをファイルシステムから切り離す。
  private func makeDetector(
    _ stub: ProcessRunnerStub,
    unreachable: Set<String> = []
  ) throws -> GitWorktreeDetector {
    GitWorktreeDetector(
      projectRunner: try testGitRunner(directory: projectDirectory, processRunner: stub),
      makeRunner: { directory throws(GitRunnerError) in
        try testGitRunner(directory: directory.path, processRunner: stub)
      },
      isWorktreeReachable: { !unreachable.contains($0) }
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

private let revParseFailure = ProcessRunResult(
  exitCode: 128,
  stdout: "",
  stderr: "fatal: cannot change to '/wt/beta': No such file or directory\n"
)

/// fixture と同じ構成の repository で `rev-parse --git-dir` を撃った結果 (git 2.50.1 実測)。
/// `wt2 with space` の管理ディレクトリ名は git がサニタイズして `wt2-with-space` になるため、
/// 作業ツリー名を連結するだけでは実挙動を再現できない。`nil` は main worktree を表す。
private let fixtureAdministrativeNames: [String: String?] = [
  "repo": nil, "wt1": "wt1", "wt2 with space": "wt2-with-space", "wt3-日本語🚀": "wt3-日本語🚀",
]

private typealias StubResult = Result<ProcessRunResult, ProcessRunnerError>
private typealias StubHandler = @Sendable ([String]) -> StubResult

/// `-C` の作業ツリーごとに `rev-parse --git-dir --git-common-dir` の応答を差し替える。
/// Project 自身への問い合わせは `worktree list` と common dir 単独の2つで、引数で見分ける。
private func stubHandler(
  listOutput: String,
  gitDirectories: @escaping @Sendable (String) -> StubResult
) -> StubHandler {
  { arguments in
    guard let directory = repositoryDirectory(of: arguments) else { return .failure(.cancelled) }
    if arguments.contains("worktree") { return success(listOutput) }
    guard arguments.contains("--git-dir") else { return success("\(commonDirectory)\n") }
    return gitDirectories(directory)
  }
}

private func fixtureHandler(_ listOutput: String) -> StubHandler {
  stubHandler(listOutput: listOutput) { directory in
    let name = URL(fileURLWithPath: directory).lastPathComponent
    guard let administrativeName = fixtureAdministrativeNames[name] else {
      return .failure(.cancelled)
    }
    return success(
      gitDirectoryLines(
        administrativeName.map { "\(commonDirectory)/worktrees/\($0)" } ?? commonDirectory))
  }
}

/// `rev-parse` には `<common>/worktrees/<作業ツリー名>` を返す。サニタイズの要らない名前でしか
/// 実挙動と一致しないので、安定 ID の値そのものを検証しないテストにだけ使う。
private func listThenGitDirectories(
  _ listOutput: String,
  failingIn failingDirectory: String? = nil
) -> StubHandler {
  stubHandler(listOutput: listOutput) { directory in
    guard directory != failingDirectory else { return .success(revParseFailure) }
    return success(gitDirectoryLines(linkedGitDirectory(of: directory)))
  }
}

/// `rev-parse` の出力だけを差し替えて、解釈できない出力の扱いを見るためのハンドラ。
private func listThenFixedGitDirectoryOutput(_ stdout: String) -> StubHandler {
  stubHandler(listOutput: singleWorktreeList) { _ in success(stdout) }
}

private func linkedGitDirectory(of worktreePath: String) -> String {
  "\(commonDirectory)/worktrees/\(URL(fileURLWithPath: worktreePath).lastPathComponent)"
}

/// `rev-parse --git-dir --git-common-dir` の2行出力。
private func gitDirectoryLines(_ gitDirectory: String) -> String {
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
