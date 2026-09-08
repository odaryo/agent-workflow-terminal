import Foundation
import TerminalCore
import Testing

@testable import Adapters

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

  /// 検証対象の `GitRunner` に汚れた global config を読ませる。`GitRunner` から `HOME` を落とす
  /// (= config を読ませない) 対処は credential helper や include まで殺すので採れない。偽の
  /// `HOME` に `.gitconfig` を置くのが、実運用の `~/.gitconfig` と同じ経路になる。
  func runner(globalConfig: String, in worktreeName: String? = nil) throws -> GitRunner {
    let home = root.appending(path: "home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try globalConfig.write(
      to: home.appending(path: ".gitconfig"), atomically: true, encoding: .utf8)
    return try GitRunner(
      repositoryDirectory: worktreeName.map { root.appending(path: $0) } ?? mainWorktree,
      processRunner: processRunner,
      executableCandidates: [executableURL],
      // `GitRunner` は `HOME` と `PATH` しか子へ渡さないので、`GIT_CONFIG_SYSTEM` を足しても
      // 効かない。system config は実 `/etc/gitconfig` のまま = 製品と同じ条件になる。
      parentEnvironment: [
        "HOME": home.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
      ],
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) })
  }

  /// gitlink を1つ巻き戻した superproject。`diff.submodule` / `diff.ignoreSubmodules` の影響は
  /// 「gitlink が指す commit だけが変わった」状態でしか観測できない。
  func addRewoundSubmodule(name: String) async throws {
    let upstreamName = "upstream-\(name)"
    let upstream = root.appending(path: upstreamName)
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try await git(["init", "-q", "-b", "main"], in: upstreamName)
    for contents in ["s1\n", "s2\n"] {
      try contents.write(
        to: upstream.appending(path: "s.txt"), atomically: true, encoding: .utf8)
      try await git(["add", "-A"], in: upstreamName)
      try await git(
        ["commit", "-q", "-m", contents.trimmingCharacters(in: .newlines)],
        in: upstreamName)
    }
    // file 経由の submodule clone は既定で拒否される (CVE-2022-39253 の緩和)。
    try await git(
      ["-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream.path, name])
    try await git(["commit", "-q", "-m", "add \(name)"])
    try await git(["checkout", "-q", "HEAD~1"], in: "main/\(name)")
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
    let result = try await gitExitCode(arguments, in: worktreeName)
    guard result.exitCode == 0 else {
      throw GitTestRepositoryError.commandFailed(arguments: arguments, stderr: result.stderr)
    }
  }

  /// 競合した `merge` のように、非 0 終了が期待値になる呼び出し用。
  @discardableResult
  func gitExitCode(
    _ arguments: [String], in worktreeName: String? = nil
  ) async throws -> (exitCode: Int32, stderr: String) {
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
    return (result.exitCode, result.stderr)
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
