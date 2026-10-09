import Foundation
import TerminalCore
import Testing

@testable import Adapters

private let selectedDirectory = "/repo/sub"
private let commonDirectory = "/repo/.git"

@Suite("§16.1 選ばれたディレクトリから Project を解決する (Issue #372)")
struct GitProjectResolverTests {

  // MARK: - 解決

  @Test("同一性は common dir、Project Root は worktree list の先頭にし、どちらも選んだ場所で撃つ")
  func resolvesCommonDirectoryAndMainWorktree() async throws {
    let listOutput = try fixture(named: "git-2.50.1-worktree-list-porcelain-z.txt")
    let mainPath = try #require(GitWorktreeList.parse(output: listOutput).entries.first?.path)
    let stub = ProcessRunnerStub(
      revParse: success("\(commonDirectory)\n"), worktreeList: success(listOutput))

    let project = try await makeResolver(stub).resolve(
      directory: URL(fileURLWithPath: selectedDirectory))

    #expect(project.commonDirectory.rawValue == commonDirectory)
    #expect(project.directory == mainPath)
    #expect(
      await stub.invocations == [
        [
          "--no-optional-locks", "-C", selectedDirectory, "--no-pager",
          "rev-parse", "--path-format=absolute", "--git-common-dir",
        ],
        [
          "--no-optional-locks", "-C", selectedDirectory, "--no-pager",
          "worktree", "list", "--porcelain", "-z",
        ],
      ])
  }

  /// bare repository の先頭 entry は bare ディレクトリ自身 (git 2.50.1 実測)。設計書 §2.3 の
  /// とおり Project Root を持たない Project として登録できなければならない。
  @Test("bare repository では bare ディレクトリを起点にする")
  func resolvesBareRepositoryToBareDirectory() async throws {
    let listOutput = try fixture(named: "git-2.50.1-worktree-list-porcelain-z-bare.txt")
    let barePath = try #require(GitWorktreeList.parse(output: listOutput).entries.first?.path)
    let stub = ProcessRunnerStub(
      revParse: success("\(barePath)\n"),
      worktreeList: success(listOutput + "worktree /wt/alpha\0branch refs/heads/alpha\0\0"))

    let project = try await makeResolver(stub).resolve(
      directory: URL(fileURLWithPath: "/wt/alpha"))

    #expect(project.commonDirectory.rawValue == barePath)
    #expect(project.directory == barePath)
  }

  // MARK: - 失敗

  @Test("ディレクトリとして開けないパスは git を撃たずに失敗する")
  func unreachableDirectoryFailsWithoutRunningGit() async throws {
    let stub = ProcessRunnerStub(
      revParse: success("\(commonDirectory)\n"), worktreeList: success(""))

    let error = await resolutionError(
      makeResolver(stub, reachable: false), directory: selectedDirectory)

    #expect(error == .directoryUnreachable(path: selectedDirectory))
    #expect(await stub.invocations.isEmpty)
  }

  @Test("git が repository として解決しなかったら notARepository で、stderr を残す")
  func commandFailureIsNotARepository() async throws {
    let failure = ProcessRunResult(
      exitCode: 128, stdout: "",
      stderr: "fatal: not a git repository (or any of the parent directories): .git\n")
    let stub = ProcessRunnerStub(revParse: .success(failure), worktreeList: success(""))

    let error = await resolutionError(makeResolver(stub), directory: selectedDirectory)

    #expect(
      error
        == .notARepository(
          path: selectedDirectory,
          .commandFailed(exitCode: 128, stdout: "", stderr: failure.stderr)))
  }

  @Test("git の終了を確かめられなかった失敗は notARepository にしない")
  func processFailureIsNotClassifiedAsNotARepository() async throws {
    let stub = ProcessRunnerStub(revParse: .failure(.cancelled), worktreeList: success(""))

    let error = await resolutionError(makeResolver(stub), directory: selectedDirectory)

    #expect(error == .git(.process(.cancelled)))
  }

  @Test(
    "common dir の出力が絶対パス1行でなければ失敗する",
    arguments: ["", "\n", "relative/.git\n", "/a/.git\n/b/.git\n", "/a/.git"]
  )
  func unexpectedCommonDirectoryOutputFails(output: String) async throws {
    let stub = ProcessRunnerStub(revParse: success(output), worktreeList: success(""))

    let error = await resolutionError(makeResolver(stub), directory: selectedDirectory)

    #expect(error == .unexpectedCommonDirectoryOutput(output: output))
  }

  @Test("worktree list が空なら Project Root を決められず失敗する")
  func emptyWorktreeListFails() async throws {
    let stub = ProcessRunnerStub(
      revParse: success("\(commonDirectory)\n"), worktreeList: success(""))

    let error = await resolutionError(makeResolver(stub), directory: selectedDirectory)

    #expect(error == .emptyWorktreeList)
  }

  @Test("worktree list に解釈できない record があれば先頭を信用せず失敗する")
  func malformedWorktreeListFails() async throws {
    let stub = ProcessRunnerStub(
      revParse: success("\(commonDirectory)\n"),
      worktreeList: success("HEAD abc\0\0worktree /repo\0\0"))

    let error = await resolutionError(makeResolver(stub), directory: selectedDirectory)

    guard case .malformedWorktreeList(let failures) = error else {
      Issue.record("malformedWorktreeList を期待したが \(String(describing: error))")
      return
    }
    #expect(failures.map(\.recordNumber) == [1])
  }

  // MARK: - 登録済み Project の再確認

  @Test("登録したディレクトリが同じ repository のままなら利用できる")
  func sameRepositoryIsAvailable() async throws {
    let stub = ProcessRunnerStub(
      revParse: success("\(commonDirectory)\n"), worktreeList: success("worktree /repo\0\0"))

    let availability = await makeResolver(stub).availability(of: try registered())

    #expect(availability == .available)
  }

  @Test("登録したディレクトリが別の repository を指していたら利用できない")
  func replacedRepositoryIsUnavailable() async throws {
    let stub = ProcessRunnerStub(
      revParse: success("/other/.git\n"), worktreeList: success("worktree /repo\0\0"))

    let availability = await makeResolver(stub).availability(of: try registered())

    #expect(
      availability
        == .unavailable(.replaced(by: try #require(WorktreeIdentity(rawValue: "/other/.git")))))
  }

  @Test("登録したディレクトリへ到達できなければ理由付きで利用できない")
  func unreachableRegisteredDirectoryIsUnavailable() async throws {
    let stub = ProcessRunnerStub(
      revParse: success("\(commonDirectory)\n"), worktreeList: success(""))

    let availability = await makeResolver(stub, reachable: false).availability(
      of: try registered())

    #expect(availability == .unavailable(.unresolvable(.directoryUnreachable(path: "/repo"))))
  }

  // MARK: - Helpers

  private func registered() throws -> RegisteredProject {
    RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: commonDirectory)),
      directory: "/repo"
    )
  }

  private func makeResolver(_ stub: ProcessRunnerStub, reachable: Bool = true) -> GitProjectResolver
  {
    GitProjectResolver(
      makeRunner: { directory throws(GitRunnerError) in
        try GitRunner(
          repositoryDirectory: directory,
          processRunner: stub,
          executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
          parentEnvironment: [:],
          isExecutableFile: { _ in true }
        )
      },
      isDirectoryReachable: { _ in reachable }
    )
  }

  private func resolutionError(
    _ resolver: GitProjectResolver,
    directory: String
  ) async -> GitProjectResolutionError? {
    do {
      _ = try await resolver.resolve(directory: URL(fileURLWithPath: directory))
      return nil
    } catch {
      return error
    }
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}

// MARK: - テストダブル

private func success(_ stdout: String) -> Result<ProcessRunResult, ProcessRunnerError> {
  .success(.init(exitCode: 0, stdout: stdout, stderr: ""))
}

private actor ProcessRunnerStub: ProcessRunning {
  private let revParse: Result<ProcessRunResult, ProcessRunnerError>
  private let worktreeList: Result<ProcessRunResult, ProcessRunnerError>
  private(set) var invocations: [[String]] = []

  init(
    revParse: Result<ProcessRunResult, ProcessRunnerError>,
    worktreeList: Result<ProcessRunResult, ProcessRunnerError>
  ) {
    self.revParse = revParse
    self.worktreeList = worktreeList
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    return try (arguments.contains("rev-parse") ? revParse : worktreeList).get()
  }
}
