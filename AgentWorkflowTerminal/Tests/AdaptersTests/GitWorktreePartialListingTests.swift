import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§3.2 worktree 一覧の部分出力")
struct GitWorktreePartialListingTests {
  @Test(
    "exit 128 の部分出力から main と wt1 を検出し、一覧の失敗も返す",
    arguments: ["unreadable", "dangling-symlink", "directory"]
  )
  func detectsCompletedRecordsAfterListingFailure(failure: String) async throws {
    let output = try fixture(failure)
    let stderr = "fatal: failed to read '.git/worktrees/wt2/locked': \(reason(failure))\n"
    let runner = PartialListingProcessStub(listings: [
      .success(.init(exitCode: 128, stdout: output, stderr: stderr))
    ])

    let result = try await detector(runner).scan()

    #expect(
      result.detected.map { URL(fileURLWithPath: $0.worktreePath).lastPathComponent } == [
        "main", "wt1",
      ])
    #expect(result.detected.map(\.branch) == ["main", "wt1"])
    #expect(result.detected.map(\.isProjectRoot) == [true, false])
    #expect(result.failures.isEmpty)
    #expect(result.listingFailure == .commandFailed(exitCode: 128, stdout: output, stderr: stderr))
  }

  @Test(
    "exit 128 で完全な record が無ければ一覧の失敗を throw する",
    arguments: ["", "worktree /wt/alpha\0branch refs/heads/alpha\0", "HEAD abc\0"]
  )
  func throwsWithoutCompletedRecords(output: String) async throws {
    let stderr = "fatal: incomplete listing\n"
    let runner = PartialListingProcessStub(listings: [
      .success(.init(exitCode: 128, stdout: output, stderr: stderr))
    ])
    let subject = try detector(runner)

    await #expect(
      throws: GitWorktreeScanError.list(
        .commandFailed(exitCode: 128, stdout: output, stderr: stderr))
    ) {
      try await subject.scan()
    }
    #expect(await runner.invocations.count == 1)
  }

  @Test(
    "commandFailed 以外は部分出力があっても一覧の失敗を throw する",
    arguments: [
      ProcessRunnerError.timedOut(
        exitCode: 128, stdout: "worktree /wt/main\0branch refs/heads/main\0\0", stderr: "timeout"),
      .cancelled,
      .launchFailed(executableURL: URL(fileURLWithPath: "/test/bin/git"), message: "unavailable"),
      .outputLimitExceeded(limit: 1024),
    ]
  )
  func throwsProcessFailure(error: ProcessRunnerError) async throws {
    let runner = PartialListingProcessStub(listings: [.failure(error)])
    let subject = try detector(runner)

    await #expect(throws: GitWorktreeScanError.list(.process(error))) {
      try await subject.scan()
    }
    #expect(await runner.invocations.count == 1)
  }

  @Test("exit 0 の完全な一覧は listingFailure を持たない")
  func successfulListingHasNoFailure() async throws {
    let output = "worktree /wt/main\0branch refs/heads/main\0\0"
    let runner = PartialListingProcessStub(listings: [
      .success(.init(exitCode: 0, stdout: output, stderr: ""))
    ])

    let result = try await detector(runner).scan()

    #expect(result.listingFailure == nil)
    #expect(result.detected.map(\.worktreePath) == ["/wt/main"])
    #expect(result.failures.isEmpty)
  }

  @Test("部分出力の次のスキャンで一覧が回復すれば全件を検出し listingFailure を残さない")
  func recoversOnNextScan() async throws {
    let partial = try fixture("unreadable")
    let complete = partial + "\0worktree /wt/wt3\0branch refs/heads/wt3\0\0"
    let runner = PartialListingProcessStub(listings: [
      .success(.init(exitCode: 128, stdout: partial, stderr: "fatal: locked\n")),
      .success(.init(exitCode: 0, stdout: complete, stderr: "")),
    ])
    let subject = try detector(runner)

    let first = try await subject.scan()
    let second = try await subject.scan()

    #expect(first.detected.map(\.branch) == ["main", "wt1"])
    #expect(first.listingFailure != nil)
    #expect(second.listingFailure == nil)
    #expect(
      second.detected.map(\.worktreePath)
        == GitWorktreeList.parse(output: complete).entries.map(\.path))
    #expect(second.detected.map(\.branch) == ["main", "wt1", "wt2", "wt3"])
    #expect(second.failures.isEmpty)
  }

  private func fixture(_ failure: String) throws -> String {
    let url = try #require(
      Bundle.module.url(
        forResource: "git-2.50.1-worktree-list-porcelain-z-locked-\(failure).txt",
        withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }

  private func reason(_ failure: String) -> String {
    switch failure {
    case "unreadable": "Permission denied"
    case "dangling-symlink": "No such file or directory"
    default: "Is a directory"
    }
  }

  private func detector(_ processRunner: PartialListingProcessStub) throws -> GitWorktreeDetector {
    GitWorktreeDetector(
      projectRunner: try gitRunner(URL(fileURLWithPath: "/repo"), processRunner),
      makeRunner: { directory throws(GitRunnerError) in
        try gitRunner(directory, processRunner)
      },
      isWorktreeReachable: { _ in true },
      findAdministrativeDirectory: { _, _ in nil }
    )
  }
}

private func gitRunner(
  _ directory: URL, _ processRunner: PartialListingProcessStub
) throws(GitRunnerError) -> GitRunner {
  try GitRunner(
    repositoryDirectory: directory, processRunner: processRunner,
    executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
    parentEnvironment: [:], isExecutableFile: { _ in true })
}

private actor PartialListingProcessStub: ProcessRunning {
  private var listings: [Result<ProcessRunResult, ProcessRunnerError>]
  private(set) var invocations: [[String]] = []

  init(listings: [Result<ProcessRunResult, ProcessRunnerError>]) {
    self.listings = listings
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    if arguments.contains("worktree") {
      guard !listings.isEmpty else { throw .cancelled }
      return try listings.removeFirst().get()
    }
    guard arguments.contains("--git-dir") else {
      return .init(exitCode: 0, stdout: "/repo/.git\n", stderr: "")
    }
    guard let index = arguments.firstIndex(of: "-C"), index + 1 < arguments.count else {
      throw .cancelled
    }
    let name = URL(fileURLWithPath: arguments[index + 1]).lastPathComponent
    let gitDirectory = name == "main" ? "/repo/.git" : "/repo/.git/worktrees/\(name)"
    let linkedAttributes = arguments.contains("--show-prefix") ? "false\n\n" : ""
    return .init(
      exitCode: 0, stdout: "\(gitDirectory)\n/repo/.git\n" + linkedAttributes, stderr: "")
  }
}
