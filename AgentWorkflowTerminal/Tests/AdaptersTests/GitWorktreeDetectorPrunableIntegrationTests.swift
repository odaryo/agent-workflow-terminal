import Adapters
import Foundation
import TerminalCore
import Testing

@Suite(
  "prunable worktree の検出 (設計書 §3.2 / §3.5)",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1")
)
struct GitWorktreeDetectorPrunableTests {
  @Test("bare 配置で .git を消した worktree は Project Root にも task にもならない")
  func missingGitFileInBareLayoutIsSkipped() async throws {
    try await withGitRepository { repository in
      let project = repository.root.appending(path: "proj")
      let bare = project.appending(path: ".bare")
      try await repository.git(["clone", "-q", "--bare", repository.mainWorktree.path, bare.path])
      try "gitdir: ./.bare\n".write(
        to: project.appending(path: ".git"), atomically: true, encoding: .utf8)
      for name in ["feat", "keep"] {
        try await repository.git(
          ["worktree", "add", "-q", "-b", name, project.appending(path: name).path],
          in: "proj")
      }
      let removed = project.appending(path: "feat")
      let kept = project.appending(path: "keep")
      try FileManager.default.removeItem(at: removed.appending(path: ".git"))
      let detector = try GitWorktreeDetector(
        projectDirectory: project, processRunner: FoundationProcessRunner())

      let result = try await detector.scan()

      #expect(!result.detected.contains { $0.isProjectRoot })
      #expect(!result.detected.contains { $0.worktreePath == removed.path })
      let reachable = try #require(result.detected.first { $0.worktreePath == kept.path })
      #expect(reachable.isReachable)
      #expect(result.failures.isEmpty)
    }
  }

  @Test("main 内で .git を消した worktree は Project Root と同じ安定 ID で重複しない")
  func missingGitFileInsideMainWorktreeIsSkipped() async throws {
    try await withGitRepository { repository in
      let nested = repository.mainWorktree.appending(path: ".worktrees/x")
      try await repository.git(["worktree", "add", "-q", "-b", "nested", nested.path])
      try FileManager.default.removeItem(at: nested.appending(path: ".git"))

      let result = try await repository.detector().scan()

      let identities = result.detected.map(\.identity)
      #expect(Set(identities).count == identities.count)
      #expect(!result.detected.contains { $0.worktreePath == nested.path })
      #expect(result.detected.filter(\.isProjectRoot).count == 1)
      #expect(result.failures.isEmpty)
    }
  }

  @Test("bare 配置で lock した worktree の .git が消えたら、祖先への解決を失敗として返す")
  func missingGitFileInLockedBareWorktreeIsReportedAsAncestorResolution() async throws {
    try await withGitRepository { repository in
      let project = repository.root.appending(path: "proj")
      let bare = project.appending(path: ".bare")
      try await repository.git(["clone", "-q", "--bare", repository.mainWorktree.path, bare.path])
      try "gitdir: ./.bare\n".write(
        to: project.appending(path: ".git"), atomically: true, encoding: .utf8)
      for name in ["feat", "keep"] {
        try await repository.git(
          ["worktree", "add", "-q", "-b", name, project.appending(path: name).path],
          in: "proj")
      }
      let removed = project.appending(path: "feat")
      let kept = project.appending(path: "keep")
      try await repository.git(["worktree", "lock", removed.path], in: "proj")
      try FileManager.default.removeItem(at: removed.appending(path: ".git"))
      let detector = try GitWorktreeDetector(
        projectDirectory: project, processRunner: FoundationProcessRunner())

      let result = try await detector.scan()

      #expect(!result.detected.contains { $0.isProjectRoot })
      #expect(result.detected.map(\.worktreePath) == [kept.path])
      let reachable = try #require(result.detected.first)
      #expect(reachable.isReachable)
      #expect(result.failures.map(\.worktreePath) == [removed.path])
      let failure = try #require(result.failures.first)
      #expect(failure.reason == .resolvedToAncestorRepository)
    }
  }

  @Test("main 内で lock した worktree の .git が消えても Project Root と安定 ID が重複しない")
  func missingGitFileInLockedNestedWorktreeIsReportedAsAncestorResolution() async throws {
    try await withGitRepository { repository in
      let nested = repository.mainWorktree.appending(path: ".worktrees/x")
      try await repository.git(["worktree", "add", "-q", "-b", "nested", nested.path])
      try await repository.git(["worktree", "lock", nested.path])
      try FileManager.default.removeItem(at: nested.appending(path: ".git"))

      let result = try await repository.detector().scan()

      let identities = result.detected.map(\.identity)
      #expect(Set(identities).count == identities.count)
      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(
        result.detected.filter(\.isProjectRoot).map(\.worktreePath)
          == [repository.mainWorktree.path])
      #expect(result.failures.map(\.worktreePath) == [nested.path])
      let failure = try #require(result.failures.first)
      #expect(failure.reason == .resolvedToAncestorRepository)
    }
  }

  @Test("兄弟配置で lock した worktree の .git が消えたら、gitDirectory の exit 128 を返す")
  func missingGitFileInLockedSiblingWorktreeRemainsGitDirectoryFailure() async throws {
    try await withGitRepository { repository in
      let sibling = repository.root.appending(path: "sib")
      try await repository.git(["worktree", "add", "-q", "-b", "sib", "../sib"])
      try await repository.git(["worktree", "lock", sibling.path])
      try FileManager.default.removeItem(at: sibling.appending(path: ".git"))

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.failures.map(\.worktreePath) == [sibling.path])
      let failure = try #require(result.failures.first)
      guard case .gitDirectory(.commandFailed(let exitCode, _, _)) = failure.reason else {
        Issue.record("想定と違う失敗の種類: \(failure)")
        return
      }
      #expect(exitCode == 128)
    }
  }

  @Test("linked worktree の中で lock した worktree の .git が消えたら、祖先への解決を失敗として返す")
  func missingGitFileInLockedWorktreeInsideLinkedWorktreeIsReportedAsAncestorResolution()
    async throws
  {
    try await withGitRepository { repository in
      let parent = repository.root.appending(path: "feat")
      let nested = parent.appending(path: ".worktrees/y")
      try await repository.git(["worktree", "add", "-q", "-b", "feat", parent.path])
      try await repository.git(["worktree", "add", "-q", "-b", "y", nested.path])
      try await repository.git(["worktree", "lock", nested.path])
      try FileManager.default.removeItem(at: nested.appending(path: ".git"))

      let result = try await repository.detector().scan()

      let identities = result.detected.map(\.identity)
      #expect(Set(identities).count == identities.count)
      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path, parent.path])
      let reachableParent = try #require(result.detected.first { $0.worktreePath == parent.path })
      #expect(reachableParent.isReachable)
      #expect(result.failures.map(\.worktreePath) == [nested.path])
      let failure = try #require(result.failures.first)
      #expect(failure.reason == .resolvedToAncestorRepository)
    }
  }

  @Test("bare 配置の linked worktree の中で lock した worktree の .git が消えたら、祖先への解決を失敗として返す")
  func missingGitFileInLockedWorktreeInsideBareLinkedWorktreeIsReportedAsAncestorResolution()
    async throws
  {
    try await withGitRepository { repository in
      let project = repository.root.appending(path: "proj")
      let bare = project.appending(path: ".bare")
      try await repository.git(["clone", "-q", "--bare", repository.mainWorktree.path, bare.path])
      try "gitdir: ./.bare\n".write(
        to: project.appending(path: ".git"), atomically: true, encoding: .utf8)
      let parent = project.appending(path: "feat")
      let nested = parent.appending(path: ".worktrees/y")
      try await repository.git(["worktree", "add", "-q", "-b", "feat", parent.path], in: "proj")
      try await repository.git(["worktree", "add", "-q", "-b", "y", nested.path], in: "proj")
      try await repository.git(["worktree", "lock", nested.path], in: "proj")
      try FileManager.default.removeItem(at: nested.appending(path: ".git"))
      let detector = try GitWorktreeDetector(
        projectDirectory: project, processRunner: FoundationProcessRunner())

      let result = try await detector.scan()

      let identities = result.detected.map(\.identity)
      #expect(Set(identities).count == identities.count)
      #expect(!result.detected.contains { $0.isProjectRoot })
      #expect(result.detected.map(\.worktreePath) == [parent.path])
      let reachableParent = try #require(result.detected.first)
      #expect(reachableParent.isReachable)
      #expect(result.failures.map(\.worktreePath) == [nested.path])
      let failure = try #require(result.failures.first)
      #expect(failure.reason == .resolvedToAncestorRepository)
    }
  }

  @Test("別の repository の中で lock した worktree の .git が消えたら、消失にせず祖先への解決を失敗として返す")
  func missingGitFileInLockedWorktreeInsideOtherRepositoryIsReportedAsAncestorResolution()
    async throws
  {
    try await withGitRepository { repository in
      let other = repository.root.appending(path: "other")
      let worktree = other.appending(path: "w")
      try await repository.git(["init", "-q", "-b", "main", other.path])
      try await repository.git(["worktree", "add", "-q", "-b", "w", worktree.path])
      try await repository.git(["worktree", "lock", worktree.path])
      try FileManager.default.removeItem(at: worktree.appending(path: ".git"))

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.failures.map(\.worktreePath) == [worktree.path])
      let failure = try #require(result.failures.first)
      #expect(failure.reason == .resolvedToAncestorRepository)
    }
  }

  // root では探索権限の制限が効かず、この経路を再現できない。
  @Test("親に入れない unlocked worktree は admin 側の安定 ID で到達不能として検出する")
  func unsearchableParentOfUnlockedWorktreeIsDetectedAsUnreachable() async throws {
    try await withGitRepository { repository in
      let parent = repository.root.appending(path: "par")
      let worktree = parent.appending(path: "w")
      try await repository.git(["worktree", "add", "-q", "-b", "blocked-parent", worktree.path])
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: parent.path)
      }

      let result = try await repository.detector().scan()

      let blocked = try #require(result.detected.first { $0.worktreePath == worktree.path })
      #expect(!blocked.isReachable)
      #expect(!blocked.isProjectRoot)
      #expect(
        blocked.identity.utf8Bytes
          == Array("\(repository.mainWorktree.path)/.git/worktrees/w".utf8))
      #expect(result.failures.isEmpty)
    }
  }

  // git worktree move は admin 側も更新するため、手で移して元パスの登録を残す。
  // root ではリンク先の探索権限の制限が効かず、prunable の前提を再現できない。
  @Test("入れないディレクトリへの symlink に置き換わった unlocked worktree は除外する")
  func prunableSymlinkToUnsearchableDirectoryIsSkipped() async throws {
    try await withGitRepository { repository in
      let worktree = repository.root.appending(path: "wt-link")
      let destination = repository.root.appending(path: "moved")
      try await repository.git(["worktree", "add", "-q", "-b", "wt-link", worktree.path])
      try FileManager.default.moveItem(at: worktree, to: destination)
      try FileManager.default.createSymbolicLink(at: worktree, withDestinationURL: destination)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o000], ofItemAtPath: destination.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: destination.path)
      }
      let runner = try repository.runner(globalConfig: "")
      let listing = try await runner.run(.worktreeList())
      let entry = try #require(
        GitWorktreeList.parse(output: listing.stdout).entries.first { $0.path == worktree.path })
      try #require(entry.prunableReason != nil)

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.failures.isEmpty)
    }
  }

  @Test("通常ファイルに置き換わった unlocked worktree は除外する")
  func prunableRegularFileAtWorkingTreePathIsSkipped() async throws {
    try await withGitRepository { repository in
      let worktree = repository.root.appending(path: "wt-file")
      try await repository.git(["worktree", "add", "-q", "-b", "wt-file", worktree.path])
      try FileManager.default.removeItem(at: worktree)
      try Data().write(to: worktree)
      // 実行権限だけで落ちる実装でも通らないよう、ディレクトリ種別の判定を必要にする。
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worktree.path)

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.failures.isEmpty)
    }
  }
}
