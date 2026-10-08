import Adapters
import Foundation
import TerminalCore
import Testing

/// `GitWorktreeDetectorIntegrationTests` と同じ `AWT_GIT_INTEGRATION` で有効にする。
private let isGitIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1"

@Suite(
  "隔離 repository での Project の解決 (設計書 §16.1 / Issue #372)",
  .enabled(if: isGitIntegrationEnabled)
)
struct GitProjectResolverIntegrationTests {

  private let resolver = GitProjectResolver(processRunner: FoundationProcessRunner())

  private func resolutionError(directory: URL) async -> GitProjectResolutionError? {
    do {
      _ = try await resolver.resolve(directory: directory)
      return nil
    } catch {
      return error
    }
  }

  @Test(
    "main worktree・linked worktree の中・サブディレクトリのどれを選んでも同じ Project に解決する",
    arguments: ["main", "wt-feat", "main/sub/dir", "wt-feat/sub"]
  )
  func resolvesToMainWorktreeFromAnywhere(selected: String) async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])
      for directory in ["main/sub/dir", "wt-feat/sub"] {
        try FileManager.default.createDirectory(
          at: repository.root.appending(path: directory), withIntermediateDirectories: true)
      }

      let project = try await resolver.resolve(
        directory: repository.root.appending(path: selected))

      #expect(
        project.commonDirectory.utf8Bytes == Array("\(repository.mainWorktree.path)/.git".utf8))
      #expect(project.directory == repository.mainWorktree.path)
    }
  }

  /// 同一性が `GitWorktreeDetector` の Project Root の安定 ID と食い違うと、Project ごとの保存先
  /// (`WorktreeInventoryStore.defaultFileURL`) と tmux session 名が Project の一覧と別の値になる。
  @Test("解決した common dir は worktree 検出の Project Root の安定 ID とバイト単位で一致する")
  func commonDirectoryMatchesDetectedProjectRoot() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])

      let project = try await resolver.resolve(
        directory: repository.root.appending(path: "wt-feat"))
      let detected = try await GitWorktreeDetector(
        projectDirectory: URL(fileURLWithPath: project.directory),
        processRunner: FoundationProcessRunner()
      ).scan().detected

      let root = try #require(detected.first { $0.isProjectRoot })
      #expect(root.identity.utf8Bytes == project.commonDirectory.utf8Bytes)
      #expect(root.worktreePath == project.directory)
    }
  }

  @Test("Git repository でないディレクトリは notARepository で失敗する")
  func nonRepositoryFails() async throws {
    try await withGitRepository { repository in
      let plain = repository.root.appending(path: "plain")
      try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

      let error = await resolutionError(directory: plain)

      guard case .notARepository(let path, .commandFailed(let exitCode, _, _)) = error else {
        Issue.record("notARepository を期待したが \(String(describing: error))")
        return
      }
      #expect(path == plain.path)
      #expect(exitCode == 128)
    }
  }

  @Test("存在しないディレクトリは git を撃たずに directoryUnreachable で失敗する")
  func missingDirectoryFails() async throws {
    try await withGitRepository { repository in
      let missing = repository.root.appending(path: "missing")

      let error = await resolutionError(directory: missing)

      #expect(error == .directoryUnreachable(path: missing.path))
    }
  }

  /// 設計書 §2.3: bare repository は Project Root を持たない Project として扱う。
  @Test("bare repository の linked worktree からは bare ディレクトリを起点にした Project に解決する")
  func resolvesBareRepository() async throws {
    try await withGitRepository { repository in
      let bare = repository.root.appending(path: "bare.git")
      try await repository.git(["clone", "-q", "--bare", repository.mainWorktree.path, bare.path])
      try await repository.git(["worktree", "add", "-q", "-b", "bw", "../bwt"], in: "bare.git")

      let project = try await resolver.resolve(directory: repository.root.appending(path: "bwt"))

      #expect(project.commonDirectory.utf8Bytes == Array(bare.path.utf8))
      #expect(project.directory == bare.path)
    }
  }

  /// common dir は Project の同一性そのものなので、同じパスに作り直した repository は同じ Project
  /// になる。`replaced` が拾うのは、登録したパスが**別の common dir** を返すようになった場合で、
  /// ここでは登録したパスが別 repository の linked worktree に置き換わった形で再現する。
  @Test("登録したディレクトリが別の repository の worktree に置き換わったら replaced になる")
  func replacedRepositoryIsUnavailable() async throws {
    try await withGitRepository { repository in
      let project = try await resolver.resolve(directory: repository.mainWorktree)
      #expect(await resolver.availability(of: project) == .available)

      let other = repository.root.appending(path: "other")
      try await repository.git(["init", "-q", "-b", "main", other.path])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "init"], in: "other")
      try FileManager.default.removeItem(at: repository.mainWorktree)
      try await repository.git(
        ["worktree", "add", "-q", "-b", "takeover", repository.mainWorktree.path], in: "other")

      let availability = await resolver.availability(of: project)

      guard case .unavailable(.replaced(let found)) = availability else {
        Issue.record("replaced を期待したが \(availability)")
        return
      }
      #expect(found.utf8Bytes == Array("\(other.path)/.git".utf8))
    }
  }

  @Test("登録したディレクトリが消えたら directoryUnreachable で利用できない")
  func removedRepositoryIsUnavailable() async throws {
    try await withGitRepository { repository in
      let project = try await resolver.resolve(directory: repository.mainWorktree)

      try FileManager.default.removeItem(at: repository.mainWorktree)
      let availability = await resolver.availability(of: project)

      #expect(
        availability
          == .unavailable(.unresolvable(.directoryUnreachable(path: repository.mainWorktree.path))))
    }
  }
}
