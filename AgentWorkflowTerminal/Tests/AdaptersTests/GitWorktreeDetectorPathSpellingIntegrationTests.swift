import Adapters
import Foundation
import TerminalCore
import Testing

/// `worktree list` のパスは gitdir ファイルに記録された文字列 (打った表記) で、ディスク上の表記
/// とずれ得る (Issue #502 の再レビュー、git 2.50.1 実測)。ずれても正常な linked worktree を
/// 祖先への解決と誤らないこと。
@Suite(
  "表記のずれた linked worktree の検出 (設計書 §3.2 / §3.5)",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1")
)
struct GitWorktreeDetectorPathSpellingTests {
  /// `FileManager` が作るディレクトリ名は NFD、`core.precomposeunicode=true` の git が記録する
  /// linked worktree のパスは NFC になる (実測)。
  @Test("NFD のディレクトリの下で作った linked worktree は、記録が NFC でも到達可能として検出する")
  func linkedWorktreeUnderDecomposedDirectoryIsDetected() async throws {
    try await withGitRepository { repository in
      let main = repository.root.appending(path: "プロジェクト/main")
      try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
      try #require(!isPrecomposed(main.path))
      try await repository.git(["-C", main.path, "init", "-q", "-b", "main"])
      try await repository.git(["-C", main.path, "commit", "-q", "--allow-empty", "-m", "init"])
      try await repository.git(
        ["-C", main.path, "worktree", "add", "-q", "-b", "t3", "\(main.path)/../t3"])
      let linkedPath = try await linkedWorktreePath(repository, in: "プロジェクト/main")
      try #require(isPrecomposed(linkedPath))

      let result = try await GitWorktreeDetector(
        projectDirectory: main, processRunner: FoundationProcessRunner()
      ).scan()

      #expect(result.failures.isEmpty)
      #expect(result.detected.count == 2)
      let linked = try #require(result.detected.first { !$0.isProjectRoot })
      #expect(Array(linked.worktreePath.utf8) == Array(linkedPath.utf8))
      #expect(linked.isReachable)
    }
  }

  @Test(
    "大小を変えたパスで作った linked worktree は、到達可能として検出する",
    .enabled(if: isTemporaryVolumeCaseInsensitive())
  )
  func linkedWorktreeAddedThroughDifferentlyCasedPathIsDetected() async throws {
    try await withGitRepository { repository in
      let main = repository.root.appending(path: "R4/main")
      let differentlyCased = repository.root.appending(path: "r4/main")
      try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
      try await repository.git(["-C", main.path, "init", "-q", "-b", "main"])
      try await repository.git(["-C", main.path, "commit", "-q", "--allow-empty", "-m", "init"])
      try await repository.git(
        [
          "-C", differentlyCased.path, "worktree", "add", "-q", "-b", "wc2",
          "\(differentlyCased.path)/../wc2",
        ])
      let linkedPath = try await linkedWorktreePath(repository, in: "R4/main")
      try #require(linkedPath.hasSuffix("/r4/wc2"))

      let result = try await GitWorktreeDetector(
        projectDirectory: main, processRunner: FoundationProcessRunner()
      ).scan()

      #expect(result.failures.isEmpty)
      #expect(result.detected.count == 2)
      let linked = try #require(result.detected.first { !$0.isProjectRoot })
      #expect(linked.worktreePath == linkedPath)
      #expect(linked.isReachable)
    }
  }

  private func linkedWorktreePath(
    _ repository: GitTestRepository, in mainName: String
  ) async throws -> String {
    let listing = try await repository.runner(globalConfig: "", in: mainName).run(.worktreeList())
    let entries = GitWorktreeList.parse(output: listing.stdout).entries
    try #require(entries.count == 2)
    return entries[1].path
  }

  private func isPrecomposed(_ path: String) -> Bool {
    Array(path.utf8) == Array(path.precomposedStringWithCanonicalMapping.utf8)
  }
}

/// case-sensitive なボリュームでは大小の違うパスが別物になり、前提の配置を作れない。
private func isTemporaryVolumeCaseInsensitive() -> Bool {
  let values = try? URL(fileURLWithPath: "/private/tmp")
    .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
  return values?.volumeSupportsCaseSensitiveNames == false
}
