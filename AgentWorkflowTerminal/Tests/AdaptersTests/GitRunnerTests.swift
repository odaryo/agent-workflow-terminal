import Foundation
import Testing

@testable import Adapters

// fixture は Issue #15 記載の共通 repository から git 2.50.1 で採取。
// この suite は ProcessRunning mock のみを使い、git は実行しない。
@Suite("§17.1 読み取り専用 git 実行境界")
struct GitRunnerTests {
  @Test("revision と pathspec を無害化する")
  func validatesInputs() {
    #expect(GitRevision("") == nil)
    #expect(GitRevision("-n") == nil)
    #expect(GitRevision(".bad") == nil)
    #expect(GitRevision("a\nb") == nil)
    #expect(GitPathspec("-x") == nil)
    #expect(GitPathspec("a\0b") == nil)
    #expect(GitRevision("HEAD") == .head)
    #expect(GitPathspec(":(glob)**/*.swift") != nil)
  }

  @Test("factory が range と pathspec を -- の後ろへ置く")
  func buildsCommands() throws {
    let main = try #require(GitRevision("main"))
    let topic = try #require(GitRevision("topic"))
    let path = try #require(GitPathspec("Sources/a.swift"))
    let range = GitRevisionRange.threeDot(from: main, to: topic)
    #expect(
      GitReadCommand.status(includeIgnored: true).arguments == [
        "status", "--porcelain=v2", "--branch", "--renames", "--untracked-files=normal", "-z",
        "--ignored=matching",
      ])
    #expect(GitReadCommand.worktreeList().arguments == ["worktree", "list", "--porcelain", "-z"])
    #expect(
      GitReadCommand.log(range: range, maxCount: 2, pathspec: [path]).arguments == [
        "log", "-z", "--no-show-signature", "--encoding=UTF-8", "--format=" + GitLog.format,
        "--max-count=2", "main...topic", "--", "Sources/a.swift",
      ])
    #expect(GitReadCommand.log(maxCount: 0).arguments.suffix(1) == ["--"])
    #expect(
      GitReadCommand.diffFileSummaries(.index(against: .head), pathspec: [path]).arguments == [
        "diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--raw", "--numstat",
        "--no-abbrev", "-z", "--cached", "HEAD", "--", "Sources/a.swift",
      ])
    #expect(
      GitReadCommand.diffPatch(.workingTree(against: .head)).arguments == [
        "diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--patch", "--no-color",
        "HEAD", "--",
      ])
  }

  @Test("共通引数・限定環境・既定値を実行層へ渡す")
  func runsReadCommand() async throws {
    let spy = GitProcessSpy(result: .success(.init(exitCode: 0, stdout: "ok", stderr: "")))
    let runner = try makeRunner(spy: spy)
    _ = try await runner.run(.status())
    let call = try #require(await spy.calls.first)
    #expect(
      call.arguments == [
        "--no-optional-locks", "-C", "/repo", "--no-pager", "status", "--porcelain=v2", "--branch",
        "--renames", "--untracked-files=normal", "-z",
      ])
    #expect(call.environment == ["LC_ALL": "C", "HOME": "/home", "PATH": "/bin"])
    #expect(call.timeout == .seconds(30))
    #expect(call.outputLimit == GitRunner.defaultOutputLimit)
  }

  @Test("非ゼロ終了と実行層エラーを変換する")
  func convertsErrors() async throws {
    let spy = GitProcessSpy(result: .success(.init(exitCode: 3, stdout: "out", stderr: "err")))
    let runner = try makeRunner(spy: spy)
    await #expect(throws: GitRunnerError.commandFailed(exitCode: 3, stdout: "out", stderr: "err")) {
      try await runner.run(.status())
    }
  }

  @Test("repository URL と binary 候補を検証する")
  func validatesBoundary() {
    let spy = GitProcessSpy(result: .success(.init(exitCode: 0, stdout: "", stderr: "")))
    let relative = URL(fileURLWithPath: "repo", relativeTo: URL(fileURLWithPath: "/base"))
    #expect(throws: GitRunnerError.invalidRepositoryDirectory(relative)) {
      try makeRunner(spy: spy, repository: relative)
    }
    #expect(throws: GitRunnerError.binaryNotFound(candidates: [URL(fileURLWithPath: "/git")])) {
      try makeRunner(spy: spy, executable: false)
    }
  }

  @Test("標準候補は端末で優先される配置順にする")
  func ordersDefaultCandidates() {
    #expect(
      GitRunner.defaultExecutableCandidates.map(\.path) == [
        "/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git",
      ])
  }

  private func makeRunner(
    spy: GitProcessSpy, repository: URL = URL(fileURLWithPath: "/repo"), executable: Bool = true
  ) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: repository, processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/git")],
      parentEnvironment: [
        "HOME": "/home", "PATH": "/bin", "GIT_DIR": "/wrong", "GIT_CONFIG_GLOBAL": "/wrong",
        "LANG": "ja",
      ], isExecutableFile: { _ in executable })
  }
}

private actor GitProcessSpy: ProcessRunning {
  struct Call: Sendable {
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
    let outputLimit: Int
  }
  private(set) var calls: [Call] = []
  let result: Result<ProcessRunResult, ProcessRunnerError>
  init(result: Result<ProcessRunResult, ProcessRunnerError>) {
    self.result = result
  }
  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(
      .init(
        arguments: arguments, environment: environment, timeout: timeout, outputLimit: outputLimit))
    return try result.get()
  }
}
