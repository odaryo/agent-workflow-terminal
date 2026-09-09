import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 同じ `@Suite` の続き。別の型にすると CI の統合テスト検査 (suite 数を完全一致で見る
/// `scripts/check-integration-ran.sh`) の期待値が動くため、extension で足す。
extension GitWorktreeDetectorIntegrationTests {

  /// gitfile 破壊の経路。git 2.50.1 (Apple Git-155) 実測: 0 バイトの `.git` に `worktree list` は
  /// `prunable` を付けず、`rev-parse --path-format=absolute --git-dir --git-common-dir` は
  /// `fatal: invalid gitfile format` の exit 128、作業ツリー自体は `-d` かつ `-x` で到達できる。
  /// `describe` はこれを `.failed(.gitDirectory)` にするので `detected` に載らない。
  @Test("gitfile が壊れた1回のスキャンで、Active 指定が保存表現から消えない")
  func brokenGitFileDoesNotDropTheActivationFromThePersistedInventory() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-keep", "../wt-keep"])
      try await repository.git(["worktree", "add", "-q", "-b", "wt-active", "../wt-active"])
      let active = repository.root.appending(path: "wt-active")
      let gitfile = active.appending(path: ".git")
      let intact = try Data(contentsOf: gitfile)

      let detector = try repository.detector()
      let first = reconcileDetectedWorktrees(
        detected: try await detector.scan().detected, previous: nil)
      // ユーザーが Active にした状態から始める。ここが消えないことがこのテストの主題。
      let previous = WorktreeInventory(
        projectRoot: first.inventory.projectRoot,
        taskWorktrees: first.inventory.taskWorktrees.map {
          TaskWorktree(
            detected: $0.detected,
            activation: $0.detected.worktreePath == active.path ? .active : .inactive)
        })

      try Data().write(to: gitfile)
      let broken = try await detector.scan()
      #expect(broken.failures.map(\.worktreePath) == [active.path])
      #expect(broken.detected.allSatisfy { $0.worktreePath != active.path })

      let retained = reconcileDetectedWorktrees(
        detected: broken.detected,
        previous: previous,
        unobserved: broken.failures.map(\.worktreePath)
      )

      #expect(retained.disappeared.isEmpty)
      #expect(retained.unobserved.count == 1)
      let held = try #require(
        retained.inventory.taskWorktrees.first { $0.detected.worktreePath == active.path })
      #expect(held.activation == .active)
      #expect(held.detected.observation == .observationFailed)
      // 保持した entry は末尾へ回るので順序は変わり得る (`reconcileDetectedWorktrees`)。
      // ここで見たいのは保存表現の中身が1件も欠けていないことである。
      let persisted = PersistedWorktreeInventory(retained.inventory)
      let before = PersistedWorktreeInventory(previous)
      #expect(persisted.projectRoot == before.projectRoot)
      #expect(Set(persisted.taskWorktrees) == Set(before.taskWorktrees))

      // 復帰しても新規出現にならず、Active のまま戻る。
      try intact.write(to: gitfile)
      let recovered = reconcileDetectedWorktrees(
        detected: try await detector.scan().detected, previous: retained.inventory)
      #expect(recovered.appeared.isEmpty)
      #expect(recovered.disappeared.isEmpty)
      let back = try #require(
        recovered.inventory.taskWorktrees.first { $0.detected.worktreePath == active.path })
      #expect(back.activation == .active)
      #expect(back.detected.observation == .reachable)
      #expect(back.identity == held.identity)
    }
  }

  /// timeout の経路。`rev-parse` が exit code を返さないので `describe` は到達可能性を確かめず
  /// (`isReachableWorkingTree` の doc)、`.failed(.gitDirectory(.process(.timedOut)))` になる。
  /// 実プロセスで起こすため、対象の作業ツリーの `rev-parse` だけ `/bin/sleep` に化ける git の
  /// 代役と、短い `entryTimeout` を使う (計測: 200 ミリ秒の指定で 0.21 秒で `.timedOut`)。
  @Test("git が応答しないスキャンでも、Active 指定が保存表現から消えない")
  func timedOutEntryDoesNotDropTheActivationFromThePersistedInventory() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-keep", "../wt-keep"])
      try await repository.git(["worktree", "add", "-q", "-b", "wt-active", "../wt-active"])
      let active = repository.root.appending(path: "wt-active")

      let first = reconcileDetectedWorktrees(
        detected: try await repository.detector().scan().detected, previous: nil)
      let previous = WorktreeInventory(
        projectRoot: first.inventory.projectRoot,
        taskWorktrees: first.inventory.taskWorktrees.map {
          TaskWorktree(
            detected: $0.detected,
            activation: $0.detected.worktreePath == active.path ? .active : .inactive)
        })

      let shim = try repository.sleepingGitShim(revParseIn: active.path)
      let stalled =
        try await repository
        .detector(executable: shim, entryTimeout: .milliseconds(200))
        .scan()

      #expect(stalled.failures.map(\.worktreePath) == [active.path])
      let failure = try #require(stalled.failures.first)
      guard case .gitDirectory(.process(.timedOut)) = failure.reason else {
        Issue.record("想定と違う失敗の種類: \(failure)")
        return
      }

      let retained = reconcileDetectedWorktrees(
        detected: stalled.detected,
        previous: previous,
        unobserved: stalled.failures.map(\.worktreePath)
      )

      #expect(retained.disappeared.isEmpty)
      #expect(retained.unobserved.count == 1)
      let held = try #require(
        retained.inventory.taskWorktrees.first { $0.detected.worktreePath == active.path })
      #expect(held.activation == .active)
      #expect(held.detected.observation == .observationFailed)
      // 保持した entry は末尾へ回るので順序は変わり得る (`reconcileDetectedWorktrees`)。
      // ここで見たいのは保存表現の中身が1件も欠けていないことである。
      let persisted = PersistedWorktreeInventory(retained.inventory)
      let before = PersistedWorktreeInventory(previous)
      #expect(persisted.projectRoot == before.projectRoot)
      #expect(Set(persisted.taskWorktrees) == Set(before.taskWorktrees))

      // shim を使わない次のスキャンで復帰し、新規出現にならない。
      let recovered = reconcileDetectedWorktrees(
        detected: try await repository.detector().scan().detected, previous: retained.inventory)
      #expect(recovered.appeared.isEmpty)
      #expect(recovered.disappeared.isEmpty)
      let back = try #require(
        recovered.inventory.taskWorktrees.first { $0.detected.worktreePath == active.path })
      #expect(back.activation == .active)
      #expect(back.detected.observation == .reachable)
      #expect(back.identity == held.identity)
    }
  }

}
