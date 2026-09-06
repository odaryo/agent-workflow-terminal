import Adapters
import Foundation
import TerminalCore
import Testing

/// 実 git を使う統合テストが共有する隔離 repository。
///
/// `/private/tmp` の下に作るのは、`NSTemporaryDirectory()` が返す `/var/...` を git が
/// 実体パス (`/private/var/...`) へ解決してしまい、`worktree list` の出力と作成時のパスが
/// 文字列として一致しなくなるためである。テスト終了時に必ず消す。
func withGitRepository(_ body: (GitTestRepository) async throws -> Void) async throws {
  let root = URL(fileURLWithPath: "/private/tmp")
    .appending(path: "awt-git-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let repository = try GitTestRepository(root: root)
  try await repository.initialize()
  try await body(repository)
}

struct GitTestRepository {
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
      throw GitTestRepositoryError.commandFailed(arguments: arguments, stderr: result.stderr)
    }
  }
}

enum GitTestRepositoryError: Error {
  case commandFailed(arguments: [String], stderr: String)
}

extension WorktreeIdentity {
  /// `rawValue` を `String` として比べると Unicode の正準等価で一致してしまい、NFC と NFD の
  /// 食い違いを見逃す。この型の同一性は UTF-8 バイト列で定義されている (`WorktreeIdentity`)。
  var utf8Bytes: [UInt8] { Array(rawValue.utf8) }
}
