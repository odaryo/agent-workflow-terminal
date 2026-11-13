import Adapters
import Foundation
import TerminalCore
import Testing

@Suite(
  "§3.4 Close は replace ref と grafts による見かけのマージを無視する",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1"),
  .serialized
)
struct GitCloseHistoryRewriteIntegrationTests {
  @Test("実際には未マージの feature を履歴書き換えで merged にしない", arguments: [true, false])
  func rejectsRewrittenAncestry(usesReplaceRef: Bool) async throws {
    try await withGitRepository { repository in
      let base = try await repository.branchTip("main")
      try await repository.git(["worktree", "add", "-q", "-b", "feature", "../feature"])
      try "feature\n".write(
        to: repository.root.appending(path: "feature/feature.txt"), atomically: true,
        encoding: .utf8)
      try await repository.git(["add", "-A"], in: "feature")
      try await repository.git(["commit", "-q", "-m", "feature"], in: "feature")
      try "main\n".write(
        to: repository.mainWorktree.appending(path: "main.txt"), atomically: true,
        encoding: .utf8)
      try await repository.git(["add", "-A"])
      try await repository.git(["commit", "-q", "-m", "main"])
      let main = try await repository.branchTip("main")
      let feature = try await repository.branchTip("feature")
      let ancestorArguments = ["merge-base", "--is-ancestor", feature.rawValue, main.rawValue]
      #expect(try await repository.gitExitCode(ancestorArguments).exitCode == 1)

      if usesReplaceRef {
        try await repository.git([
          "replace", "--graft", main.rawValue, base.rawValue, feature.rawValue,
        ])
      } else {
        try "\(main.rawValue) \(base.rawValue) \(feature.rawValue)\n".write(
          to: repository.mainWorktree.appending(path: ".git/info/grafts"), atomically: true,
          encoding: .utf8)
      }
      #expect(try await repository.gitExitCode(ancestorArguments, in: "feature").exitCode == 0)

      let target = DetectedWorktree(
        identity: try #require(
          WorktreeIdentity(
            rawValue: repository.mainWorktree.appending(path: ".git/worktrees/feature").path)),
        worktreePath: repository.root.appending(path: "feature").path,
        branch: "feature", isProjectRoot: false)
      let cache = GitBranchMergeCache()
      let inspector = try GitCloseSafetyInspector(
        target: target, processRunner: ConfigIsolatedGitProcessRunner(), mergeCache: cache)
      for _ in 0..<2 {
        let result = await inspector.inspect(projectRootBranch: "main")
        #expect(result.failures.isEmpty)
        #expect(result.report.inspection.branchMerge == .unmerged)
      }
    }
  }

  @Test("履歴書き換えを無視しても失敗時の stderr の先頭を hint で隠さない")
  func preservesFailureFirstLine() async throws {
    try await withGitRepository { repository in
      let runner = try GitRunner(
        repositoryDirectory: repository.mainWorktree,
        processRunner: ConfigIsolatedGitProcessRunner(), ignoresHistoryRewrites: true)
      let missing = try #require(GitRevision(String(repeating: "1", count: 40)))
      do {
        _ = try await runner.run(.mergeBase(.head, missing))
        Issue.record("存在しない OID への merge-base が成功した")
      } catch GitRunnerError.commandFailed(_, _, let stderr) {
        let firstLine = try #require(stderr.split(separator: "\n").first)
        #expect(!firstLine.hasPrefix("hint:"))
        #expect(firstLine.hasPrefix("fatal:"))
      }
    }
  }
}

// public init が親環境から組み立てた履歴設定は保ち、開発者の gitconfig だけを隔離する。
struct ConfigIsolatedGitProcessRunner: ProcessRunning {
  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    var environment = environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    return try await FoundationProcessRunner().run(
      executableURL: executableURL, arguments: arguments, environment: environment,
      timeout: timeout, outputLimit: outputLimit)
  }
}
