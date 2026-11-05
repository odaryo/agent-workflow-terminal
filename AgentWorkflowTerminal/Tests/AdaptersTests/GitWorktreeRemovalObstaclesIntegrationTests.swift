import Adapters
import Foundation
import TerminalCore
import Testing

@Suite(
  "§3.4 実 git の lock と submodule による削除拒否",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1"),
  .serialized)
struct GitRemovalObstaclesIntegrationTests {
  @Test("改行を含む lock 理由を porcelain の引用表現にせず読む")
  func observesLockReason() async throws {
    try await withGitRepository { repository in
      try await repository.addWorktree("topic")
      try await repository.git([
        "worktree", "lock", "--reason", "on a portable\nvolume", "../topic",
      ])
      let target = try await repository.detected(branch: "topic")
      let result = try await inspect(target)
      #expect(
        result.report.removalObstacles
          == .observed(lockReason: "on a portable\nvolume", populatedSubmodules: []))
      #expect(result.removalObstaclesFailure == nil)
    }
  }

  @Test("初期化済みと deinit 後は modules が残り削除の妨げになる", arguments: [false, true])
  func observesInitializedAndDeinitializedSubmodules(deinitialize: Bool) async throws {
    try await withGitRepository { repository in
      try await repository.addRewoundSubmodule(name: "libs/sub")
      try await repository.addWorktree("topic")
      try await repository.git(
        ["-c", "protocol.file.allow=always", "submodule", "update", "--init"], in: "topic")
      if deinitialize {
        try await repository.git(["submodule", "deinit", "-f", "--", "libs/sub"], in: "topic")
      }
      let target = try await repository.detected(branch: "topic")
      #expect(FileManager.default.fileExists(atPath: target.identity.rawValue + "/modules"))
      #expect(
        FileManager.default.fileExists(atPath: target.worktreePath + "/libs/sub/.git")
          == !deinitialize)
      let result = try await inspect(target)
      guard case .observed(let lock, _, let hasModules) = result.report.removalObstacles else {
        Issue.record("削除の妨げを観測できなかった")
        return
      }
      #expect(lock == nil)
      #expect(hasModules)
      #expect(result.removalObstaclesFailure == nil)
    }
  }

  @Test("未初期化の submodule は gitlink があっても削除の妨げにならない")
  func permitsUninitializedSubmodule() async throws {
    try await withGitRepository { repository in
      try await repository.addRewoundSubmodule(name: "libs/sub")
      try await repository.addWorktree("topic")
      let target = try await repository.detected(branch: "topic")
      #expect(!FileManager.default.fileExists(atPath: target.identity.rawValue + "/modules"))
      #expect(!FileManager.default.fileExists(atPath: target.worktreePath + "/libs/sub/.git"))
      let result = try await inspect(target)
      #expect(result.report.removalObstacles == .observed(lockReason: nil, populatedSubmodules: []))
      #expect(result.removalObstaclesFailure == nil)
    }
  }

  private func inspect(
    _ target: DetectedWorktree
  ) async throws -> GitWorktreeProgressInspectionResult {
    try await GitWorktreeProgressInspector(target: target, processRunner: FoundationProcessRunner())
      .inspect()
  }
}
