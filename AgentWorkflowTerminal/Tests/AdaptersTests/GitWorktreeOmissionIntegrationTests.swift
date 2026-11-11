import Adapters
import Foundation
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
}
