import Adapters
import Foundation
import TerminalCore
import Testing

/// 既定は無効で、CI (`swift test` を素で実行) では走らない (`GitWorktreeDetectorIntegrationTests` と同じ)。
@Suite(
  "exit 0 で record が黙って欠けた worktree 一覧の実 git での検出 (Issue #774)",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1")
)
struct GitWorktreeOmissionIntegrationTests {
  // root では chmod 000 が読み取りを妨げないため、この経路は再現しない。
  @Test(
    "exit 0 で wt2 の record が黙って欠けたら、検出できた分と一覧の失敗を返す (Issue #774)",
    arguments: ["gitdir-unreadable", "gitdir-directory"])
  func silentlyOmittedRecordMakesListingIncomplete(shape: String) async throws {
    try await withGitRepository { repository in
      for name in ["wt1", "wt2", "wt3"] {
        try await repository.git(["worktree", "add", "-q", "-b", name, "../\(name)"])
      }
      let gitdir = repository.mainWorktree.appending(path: ".git/worktrees/wt2/gitdir")
      if shape == "gitdir-unreadable" {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: gitdir.path)
      } else {
        try FileManager.default.removeItem(at: gitdir)
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: false)
      }
      defer {
        // 権限を落としたファイルだけを戻す。ディレクトリにした形は後始末でそのまま消せる。
        if shape == "gitdir-unreadable" {
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: gitdir.path)
        }
      }

      let result = try await repository.detector().scan()

      #expect(
        result.detected.map(\.worktreePath)
          == [repository.mainWorktree.path]
          + ["wt1", "wt3"].map {
            repository.root.appending(path: $0).path
          })
      #expect(
        result.listingFailure
          == .omittedRecords(.missingRecords(administrativeDirectories: 3, linkedRecords: 2)))
      #expect(result.failures.isEmpty)
    }
  }

  /// 部分一覧の回に prunable の worktree を消失にできるのは、ここで返す安定 ID が、到達できた
  /// ときの `rev-parse` の ID と一致する場合だけである。
  @Test("作業ツリーを消した worktree の prunable の安定 ID は、到達できたときの安定 ID と同じ")
  func prunableIdentityMatchesReachableIdentity() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "gone", "../gone"])
      let before = try await repository.detector().scan()
      let identity = try #require(before.detected.first { !$0.isProjectRoot }?.identity)

      try FileManager.default.removeItem(at: repository.root.appending(path: "gone"))
      let after = try await repository.detector().scan()

      #expect(before.prunable.isEmpty)
      #expect(after.prunable == [identity])
      #expect(after.detected.map(\.isProjectRoot) == [true])
      #expect(after.listingFailure == nil)
    }
  }

  @Test("不完全が続く間も remove を観測して同じ ID の再作成を Inactive にする (#870 I1)")
  func removedTaskReappearsInactiveDuringPersistentOmission() async throws {
    try await withGitRepository { repository in
      for name in ["wt1", "wt2", "wt3"] {
        try await repository.git(["worktree", "add", "-q", "-b", name, "../\(name)"])
      }
      let detector = try repository.detector()
      let initial = try await scanAndReconcile(detector, previous: nil)
      var active = initial.inventory.taskWorktrees
      for task in initial.inventory.taskWorktrees {
        active = applyingActivation(.active, of: task.identity, to: active)
      }
      let previous = WorktreeInventory(
        projectRoot: initial.inventory.projectRoot, taskWorktrees: active)
      let wt2 = try #require(active.first { $0.detected.branch == "wt2" })
      let wt3 = try #require(active.first { $0.detected.branch == "wt3" })
      #expect(active.count == 3)
      #expect(active.allSatisfy { $0.activation == .active && $0.detected.isReachable })
      let gitdir = repository.mainWorktree.appending(path: ".git/worktrees/wt2/gitdir")
      try FileManager.default.removeItem(at: gitdir)
      try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: false)

      let omitted = try await scanAndReconcile(detector, previous: previous, incomplete: true)
      #expect(omitted.inventory == previous)
      #expect(omitted.unobserved == [wt2.identity])
      #expect(omitted.disappeared.isEmpty)

      try await repository.git(["worktree", "remove", "../wt3"])
      // remove と add の間のスキャンが無い場合の Active 継承は、完全な一覧でも起きる既存の境界で対象外。
      let removed = try await scanAndReconcile(
        detector, previous: omitted.inventory, incomplete: true)
      #expect(removed.disappeared == [wt3.identity])
      #expect(removed.unobserved == [wt2.identity])
      #expect(removed.inventory.taskWorktrees.map(\.identity) == active.dropLast().map(\.identity))
      #expect(removed.inventory.taskWorktrees.allSatisfy { $0.activation == .active })
      #expect(removed.inventory.taskWorktrees.first { $0.identity == wt2.identity } == wt2)

      try await repository.git(["worktree", "add", "-q", "-b", "fresh", "../wt3"])
      let recreated = try await scanAndReconcile(
        detector, previous: removed.inventory, incomplete: true)
      let fresh = try #require(
        recreated.inventory.taskWorktrees.first { $0.detected.branch == "fresh" })
      #expect(fresh.identity == wt3.identity)
      #expect(fresh.activation == .inactive)
      #expect(fresh.detected.isReachable)
      #expect(recreated.appeared == [wt3.identity])
      #expect(recreated.disappeared.isEmpty)
      #expect(recreated.unobserved == [wt2.identity])
      #expect(recreated.inventory.taskWorktrees.first { $0.identity == wt2.identity } == wt2)
    }
  }

  private func scanAndReconcile(
    _ detector: GitWorktreeDetector, previous: WorktreeInventory?, incomplete: Bool = false
  ) async throws -> WorktreeScanResult {
    let scan = try await detector.scan(
      knownIdentities: previous?.taskWorktrees.map(\.identity) ?? [])
    #expect((scan.listingFailure != nil) == incomplete)
    #expect(scan.failures.isEmpty)
    return reconcileDetectedWorktrees(
      detected: scan.detected, previous: previous,
      unobserved: scan.failures.map(\.worktreePath), isListingComplete: scan.listingFailure == nil,
      prunable: scan.prunable, removed: scan.removed)
  }

}
