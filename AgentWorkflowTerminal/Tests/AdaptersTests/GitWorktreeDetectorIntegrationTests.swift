import Adapters
import Foundation
import TerminalCore
import Testing

/// tmux を使わないので `AWT_TMUX_INTEGRATION` とは別のゲートにする。既定は無効で、
/// CI (`swift test` を素で実行) では走らない。実 CLI に触るテストは環境依存で壊れるため
/// opt-in へ隔離するという既存方針 (docs/coding-guidelines.md §3.2 / §5.3) に合わせている。
private let isGitIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1"

@Suite(
  "隔離 repository からの worktree 検出 (設計書 §3.2 / §3.5)",
  .enabled(if: isGitIntegrationEnabled)
)
struct GitWorktreeDetectorIntegrationTests {

  @Test("linked worktree の安定 ID は <common>/worktrees/<name> になり、Project Root は1件だけ")
  func detectsProjectRootAndLinkedWorktrees() async throws {
    try await withRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])

      let detected = try await repository.detector().scan()

      #expect(detected.count == 2)
      #expect(detected.filter(\.isProjectRoot).count == 1)
      let root = try #require(detected.first { $0.isProjectRoot })
      let linked = try #require(detected.first { !$0.isProjectRoot })
      #expect(root.identity.rawValue == "\(repository.mainWorktree.path)/.git")
      #expect(
        linked.identity.rawValue == "\(repository.mainWorktree.path)/.git/worktrees/wt-feat")
      #expect(linked.worktreePath == "\(repository.root.path)/wt-feat")
      #expect(linked.branch == "wt-feat")
    }
  }

  @Test("branch を切り替えても安定 ID は変わらない")
  func stableIdentitySurvivesBranchSwitch() async throws {
    try await withRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])
      let before = try await repository.detector().scan()

      try await repository.git(["checkout", "-q", "-b", "feat2"], in: "wt-feat")
      let after = try await repository.detector().scan()

      #expect(before.map(\.identity) == after.map(\.identity))
      #expect(after.first { !$0.isProjectRoot }?.branch == "feat2")
    }
  }

  @Test("git worktree move の後も安定 ID は変わらない")
  func stableIdentitySurvivesWorktreeMove() async throws {
    try await withRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])
      let before = try await repository.detector().scan()

      try await repository.git(
        ["worktree", "move", "\(repository.root.path)/wt-feat", "\(repository.root.path)/wt-moved"])
      let after = try await repository.detector().scan()

      #expect(before.map(\.identity) == after.map(\.identity))
      let moved = try #require(after.first { !$0.isProjectRoot })
      #expect(moved.worktreePath == "\(repository.root.path)/wt-moved")
      // 管理ディレクトリ名は作成時のままで、作業ツリー名とはずれる (設計書 §3.5)。
      #expect(moved.identity.rawValue.hasSuffix("/worktrees/wt-feat"))
    }
  }

  @Test("作業ツリーを消した worktree は検出結果に現れず、スキャンも失敗しない")
  func prunableWorktreeIsSkippedWithoutFailingTheScan() async throws {
    try await withRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-gone", "../wt-gone"])
      try FileManager.default.removeItem(at: repository.root.appending(path: "wt-gone"))

      let detected = try await repository.detector().scan()

      #expect(detected.map(\.isProjectRoot) == [true])
      #expect(detected.allSatisfy { !$0.worktreePath.hasSuffix("/wt-gone") })
    }
  }

  /// git は `locked` な worktree に `prunable` を付けない (git 2.50.1 実測)。可搬ボリューム上の
  /// worktree を lock するのは `git worktree --help` が勧める運用なので、ここで失敗させると
  /// lock を外すまで Project Root を含む全 worktree が検出できなくなる。
  @Test("locked な worktree の作業ツリーが消えても、他の worktree の検出は止まらない")
  func lockedWorktreeWithMissingWorkingTreeDoesNotFailTheScan() async throws {
    try await withRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-keep", "../wt-keep"])
      try await repository.git(["worktree", "add", "-q", "-b", "wt-lock", "../wt-lock"])
      try await repository.git(
        ["worktree", "lock", "\(repository.root.path)/wt-lock", "--reason", "removable volume"])
      try FileManager.default.removeItem(at: repository.root.appending(path: "wt-lock"))

      let detected = try await repository.detector().scan()

      #expect(
        detected.map(\.worktreePath)
          == [repository.mainWorktree.path, "\(repository.root.path)/wt-keep"])
      #expect(detected.filter(\.isProjectRoot).count == 1)
    }
  }

  /// 置き換わった先でも `rev-parse` は exit 0 で、その repository の git ディレクトリを返す
  /// (git 2.50.1 実測)。`worktree list` も `prunable` を付けないので、common dir を確かめないと
  /// 無関係な repository の `.git` が安定 ID として通り、Project Root が2件になる。
  @Test("別 repository に置き換わった worktree は検出結果に含めない")
  func worktreeReplacedByAnotherRepositoryIsExcluded() async throws {
    try await withRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-swap", "../wt-swap"])
      let swapped = repository.root.appending(path: "wt-swap")
      try FileManager.default.removeItem(at: swapped)
      try FileManager.default.createDirectory(at: swapped, withIntermediateDirectories: true)
      try await repository.git(["init", "-q", "-b", "other"], in: "wt-swap")

      let detected = try await repository.detector().scan()

      #expect(detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(detected.map(\.isProjectRoot) == [true])
    }
  }

  @Test("detached HEAD の worktree では branch が nil になる")
  func detachedWorktreeHasNoBranch() async throws {
    try await withRepository { repository in
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt-detached"])

      let detected = try await repository.detector().scan()

      let detached = try #require(detected.first { !$0.isProjectRoot })
      #expect(detached.branch == nil)
      #expect(detached.worktreePath == "\(repository.root.path)/wt-detached")
    }
  }

  // MARK: - Helpers

  /// `/private/tmp` の下に作るのは、`NSTemporaryDirectory()` が返す `/var/...` を git が
  /// 実体パス (`/private/var/...`) へ解決してしまい、`worktree list` の出力と作成時のパスが
  /// 文字列として一致しなくなるためである。テスト終了時に必ず消す。
  private func withRepository(_ body: (TestRepository) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: "/private/tmp")
      .appending(path: "awt-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let repository = try TestRepository(root: root)
    try await repository.initialize()
    try await body(repository)
  }
}

private struct TestRepository {
  let root: URL
  let mainWorktree: URL
  private let executableURL: URL
  private let processRunner = FoundationProcessRunner()

  init(root: URL) throws {
    self.root = root
    self.mainWorktree = root.appending(path: "main")
    self.executableURL = try #require(
      GitRunner.defaultExecutableCandidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
  }

  func initialize() async throws {
    try FileManager.default.createDirectory(at: mainWorktree, withIntermediateDirectories: true)
    try await git(["init", "-q", "-b", "main"])
    try await git(["commit", "-q", "--allow-empty", "-m", "init"])
  }

  func detector() throws -> GitWorktreeDetector {
    try GitWorktreeDetector(
      projectDirectory: mainWorktree,
      processRunner: processRunner,
      executableCandidates: [executableURL]
    )
  }

  /// 既定は main worktree での実行。`in:` に `root` からの相対名を渡すと別の作業ツリーで走る。
  func git(_ arguments: [String], in worktreeName: String? = nil) async throws {
    let directory = worktreeName.map { root.appending(path: $0) } ?? mainWorktree
    let result = try await processRunner.run(
      executableURL: executableURL,
      arguments: ["-C", directory.path] + arguments,
      // ホストの設定を読ませない。commit には identity が要るので環境変数で与える。
      environment: [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_AUTHOR_NAME": "awt", "GIT_AUTHOR_EMAIL": "awt@example.invalid",
        "GIT_COMMITTER_NAME": "awt", "GIT_COMMITTER_EMAIL": "awt@example.invalid",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
      ],
      timeout: .seconds(30)
    )
    guard result.exitCode == 0 else {
      throw TestRepositoryError.commandFailed(arguments: arguments, stderr: result.stderr)
    }
  }
}

private enum TestRepositoryError: Error {
  case commandFailed(arguments: [String], stderr: String)
}
