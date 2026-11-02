import Adapters
import Foundation
import TerminalCore
import Testing

@Suite(
  "同じ安定 ID を返す worktree の検出 (Issue #515)",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1")
)
struct GitWorktreeDetectorSharedIdentityTests {
  @Test("feat のコピーに置き換わった cp1 は失敗にし、本物の feat を残す")
  func copiedWorktreeIsReportedAsSharedIdentity() async throws {
    try await withGitRepository { repository in
      let genuine = try await addWorktree("feat", in: repository)
      let copied = try await addLockedWorktree("cp1", in: repository)
      try FileManager.default.removeItem(at: copied)
      try FileManager.default.copyItem(at: genuine, to: copied)

      let result = try await repository.detector().scan()

      try expectGenuineWorktree(genuine, named: "feat", in: repository, result: result)
      try expectSharedIdentityFailure(copied, named: "feat", in: repository, result: result)
      #expect(result.failures.count == 1)
    }
  }

  @Test("feat の admin を指す dup は失敗にし、本物の feat を残す")
  func redirectedGitFileIsReportedAsSharedIdentity() async throws {
    try await withGitRepository { repository in
      let genuine = try await addWorktree("feat", in: repository)
      let redirected = try await addLockedWorktree("dup", in: repository)
      let gitDirectory = repository.mainWorktree.appending(path: ".git/worktrees/feat")
      try "gitdir: \(gitDirectory.path)\n".write(
        to: redirected.appending(path: ".git"), atomically: true, encoding: .utf8)

      let result = try await repository.detector().scan()

      try expectGenuineWorktree(genuine, named: "feat", in: repository, result: result)
      try expectSharedIdentityFailure(redirected, named: "feat", in: repository, result: result)
      #expect(result.failures.count == 1)
    }
  }

  @Test("feat への symlink に置き換わった sy は失敗にし、本物の feat を残す")
  func symlinkedWorktreeIsReportedAsSharedIdentity() async throws {
    try await withGitRepository { repository in
      let genuine = try await addWorktree("feat", in: repository)
      let symlink = try await addLockedWorktree("sy", in: repository)
      try FileManager.default.removeItem(at: symlink)
      try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: genuine)

      let result = try await repository.detector().scan()

      try expectGenuineWorktree(genuine, named: "feat", in: repository, result: result)
      try expectSharedIdentityFailure(symlink, named: "feat", in: repository, result: result)
      #expect(result.failures.count == 1)
    }
  }

  @Test("core.worktree が別の場所を指す f2 に遡った y2 は失敗にし、本物の f2 を残す")
  func ancestorWithSeparateWorkingTreeIsReportedAsSharedIdentity() async throws {
    try await withGitRepository { repository in
      try await repository.git(["config", "extensions.worktreeConfig", "true"])
      let genuine = try await addWorktree("f2", in: repository)
      let nested = genuine.appending(path: "y2")
      try await repository.git(["worktree", "add", "-q", "-b", "y2", nested.path])
      let workingTree = repository.root.appending(path: "f2t")
      try FileManager.default.createDirectory(at: workingTree, withIntermediateDirectories: true)
      try await repository.git(
        ["config", "--worktree", "core.worktree", workingTree.path], in: "f2")
      try await repository.git(["worktree", "lock", nested.path])
      try FileManager.default.removeItem(at: nested.appending(path: ".git"))

      let result = try await repository.detector().scan()

      try expectGenuineWorktree(genuine, named: "f2", in: repository, result: result)
      try expectSharedIdentityFailure(nested, named: "f2", in: repository, result: result)
      #expect(result.failures.count == 1)
    }
  }

  @Test("本物が検出されない同じ安定 ID の組は、どの entry も選ばず全件を失敗にする")
  func sharedIdentityWithoutGenuineEntryIsEntirelyReportedAsFailure() async throws {
    try await withGitRepository { repository in
      let genuine = try await addWorktree("feat", in: repository)
      var copies: [URL] = []
      for name in ["cp1", "dup"] {
        let copied = try await addLockedWorktree(name, in: repository)
        try FileManager.default.removeItem(at: copied)
        try FileManager.default.copyItem(at: genuine, to: copied)
        copies.append(copied)
      }
      // git worktree move は admin の gitdir も更新するため、登録を残したまま手で移す。
      // 元の entry は別 repository に置き換え、到達不能な本物として検出されるのを避ける。
      try FileManager.default.moveItem(at: genuine, to: repository.root.appending(path: "moved"))
      try await repository.git(["init", "-q", "-b", "main", genuine.path])

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.failures.count == copies.count)
      for copied in copies {
        try expectSharedIdentityFailure(copied, named: "feat", in: repository, result: result)
      }
    }
  }

  // 相対パスの gitdir は `..` を含むので、標準化で sy の symlink が解決され、admin の sy が feat の
  // パスに一致する。辿る順で sy が先に返ると本物は0件になる (#515 の Director の計測)。安全側に倒れて
  // 本物の feat も失敗になることを固定する。
  @Test("useRelativePaths で symlink の sy が feat と同じパスに並ぶ組は、本物の feat も含め全件を失敗にする")
  func relativeSymlinkGroupIsEntirelyReportedAsFailure() async throws {
    try await withGitRepository { repository in
      try await repository.git(["config", "worktree.useRelativePaths", "true"])
      let genuine = try await addWorktree("feat", in: repository)
      let symlink = try await addLockedWorktree("sy", in: repository)
      try FileManager.default.removeItem(at: symlink)
      try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: genuine)

      let result = try await repository.detector().scan()

      let gitDirectory = repository.mainWorktree.appending(path: ".git/worktrees/feat").path
      let reason = GitWorktreeEntryFailure.Reason.sharedIdentity(gitDirectory: gitDirectory)
      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.failures.map(\.worktreePath) == [genuine.path, genuine.path])
      #expect(result.failures.map(\.reason) == [reason, reason])
    }
  }

  private func addWorktree(_ name: String, in repository: GitTestRepository) async throws -> URL {
    let worktree = repository.root.appending(path: name)
    try await repository.git(["worktree", "add", "-q", "-b", name, worktree.path])
    return worktree
  }

  private func addLockedWorktree(
    _ name: String, in repository: GitTestRepository
  ) async throws -> URL {
    let worktree = try await addWorktree(name, in: repository)
    try await repository.git(["worktree", "lock", worktree.path])
    return worktree
  }

  private func expectGenuineWorktree(
    _ worktree: URL, named name: String, in repository: GitTestRepository,
    result: GitWorktreeScanResult
  ) throws {
    let gitDirectory = repository.mainWorktree.appending(path: ".git/worktrees/\(name)").path
    let identity = try #require(WorktreeIdentity(rawValue: gitDirectory))
    let detected = try #require(result.detected.first { $0.worktreePath == worktree.path })
    #expect(detected.identity == identity)
    #expect(detected.isReachable)
    #expect(!detected.isProjectRoot)
    #expect(
      result.detected.filter { $0.identity == identity }.map(\.worktreePath) == [worktree.path])
    #expect(!result.failures.contains { $0.worktreePath == worktree.path })
  }

  private func expectSharedIdentityFailure(
    _ worktree: URL, named name: String, in repository: GitTestRepository,
    result: GitWorktreeScanResult
  ) throws {
    let gitDirectory = repository.mainWorktree.appending(path: ".git/worktrees/\(name)").path
    #expect(!result.detected.contains { $0.worktreePath == worktree.path })
    let failure = try #require(result.failures.first { $0.worktreePath == worktree.path })
    #expect(failure.reason == .sharedIdentity(gitDirectory: gitDirectory))
  }
}
