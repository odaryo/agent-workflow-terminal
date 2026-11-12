import Adapters
import Foundation
import Testing

@Suite(
  "実 git での観測再利用と起動回数 (Issue #401)",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1")
)
struct GitWorktreeDetectorReuseIntegrationTests {
  @Test("linked worktree が1個でも10個でも再スキャンの git 起動は3回", arguments: [1, 10])
  func rescanUsesThreeProcesses(linkedCount: Int) async throws {
    try await withGitRepository { repository in
      for index in 1...linkedCount {
        let name = "linked-\(index)"
        try await repository.git(["worktree", "add", "-q", "-b", name, "../\(name)"])
      }
      let runner = CountingGitProcessRunner()
      let detector = try GitWorktreeDetector(
        projectDirectory: repository.mainWorktree, processRunner: runner)
      let first = try await detector.scan()
      try #require(first.failures.isEmpty)
      try #require(first.listingFailure == nil)
      try #require(first.detected.count == linkedCount + 1)
      let reusable = first.detected.filter { !$0.isProjectRoot }
      try #require(reusable.count == linkedCount)
      let before = await runner.invocations.count

      let second = try await detector.scan(reusableObservations: reusable)

      let invocations = await runner.invocations
      let rescan = Array(invocations.dropFirst(before))
      #expect(rescan.count == 3)
      #expect(rescan.filter { $0.contains("worktree") }.count == 1)
      #expect(
        rescan.filter { $0.contains("--git-common-dir") && !$0.contains("--git-dir") }.count == 1)
      #expect(rescan.filter { $0.contains("--git-dir") }.count == 1)
      #expect(second.detected == first.detected)
      #expect(second.failures.isEmpty)
      #expect(second.listingFailure == nil)
      #expect(second.prunable == first.prunable)
      #expect(second.removed == first.removed)
    }
  }
}

private actor CountingGitProcessRunner: ProcessRunning {
  private let runner = FoundationProcessRunner()
  private(set) var invocations: [[String]] = []

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    // GitRunner は親環境から GIT_CONFIG_* を渡さないため、実プロセス境界で隔離する。
    var isolatedEnvironment = environment
    isolatedEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    isolatedEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    return try await runner.run(
      executableURL: executableURL, arguments: arguments, environment: isolatedEnvironment,
      timeout: timeout, outputLimit: outputLimit)
  }
}
