import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// user の `~/.gitconfig` は `GitRunner` の子まで届く (`HOME` を渡すため)。submodule 系の
/// config はパーサの前提そのものを壊すので、command 側の option で固定できていることを確かめる。
@Suite("§9 submodule 関連 user config からの独立")
struct GitSubmoduleConfigIndependenceTests {
  /// 未設定時の出力。この3つが「パーサの前提」であり、汚した config でも一致する必要がある。
  private struct Observation: Equatable {
    let patch: String
    let summaries: String
    let status: String
  }

  private static let pollutedConfigs = [
    "[diff]\n\tsubmodule = diff\n",
    "[diff]\n\tsubmodule = log\n",
    "[diff]\n\tignoreSubmodules = all\n",
  ]

  @Test(
    "diff.submodule / diff.ignoreSubmodules を汚しても gitlink の観測が動かない",
    .timeLimit(.minutes(1)))
  func submoduleConfigDoesNotChangeOutput() async throws {
    try await withGitRepository { repository in
      try await repository.addRewoundSubmodule(name: "sub")
      let baseline = try await observe(repository, globalConfig: "")

      // baseline 自体がパーサの前提 (gitlink 1件・別 repository のファイルは現れない) であること。
      let parsed = UnifiedDiffPatch.parse(output: baseline.patch)
      #expect(parsed.failures.isEmpty)
      #expect(parsed.files.map(\.path) == ["sub"])
      #expect(parsed.files.first?.newMode == "160000")
      #expect(GitStatusPorcelainV2.parse(output: baseline.status).status.entries.count == 1)

      for config in Self.pollutedConfigs {
        let observation = try await observe(repository, globalConfig: config)
        #expect(observation == baseline, "global config: \(config.debugDescription)")
      }
    }
  }

  private func observe(
    _ repository: GitTestRepository, globalConfig: String
  ) async throws -> Observation {
    let runner = try repository.runner(globalConfig: globalConfig)
    let target = GitDiffTarget.workingTree(against: .head)
    return Observation(
      patch: try await runner.run(.diffPatch(target)).stdout,
      summaries: try await runner.run(.diffFileSummaries(target)).stdout,
      status: try await runner.run(.status()).stdout)
  }
}
