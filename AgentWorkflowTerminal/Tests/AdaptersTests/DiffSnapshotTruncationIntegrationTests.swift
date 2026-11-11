import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§7.2 実 git の小さい出力上限での部分表示")
struct DiffSnapshotTruncationIntegrationTests {
  @Test("§7.2 b の途中で打ち切った staged patch は a だけを表示する", .timeLimit(.minutes(1)))
  func truncatesStagedPatchInsideSecondFile() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      for path in ["a", "b", "c"] {
        let text =
          (0..<100).map { "\(path)-\($0)-" + String(repeating: "x", count: 32) }
          .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: root.appending(path: path))
      }
      try await repository.git(["add", "a", "b", "c"])
      let runner = try GitRunner(
        repositoryDirectory: root, processRunner: FoundationProcessRunner())
      let full = try await runner.run(.diffPatch(.index(against: .head))).stdout
      let second = try #require(full.range(of: "diff --git a/b b/b\n"))
      let cut = try #require(full.range(of: "+b-50-", range: second.upperBound..<full.endIndex))
      let limit = full[..<cut.upperBound].utf8.count
      #expect(limit < 16_384)
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: root, processRunner: FoundationProcessRunner(), diffPatchOutputLimit: limit)
      let result = try await builder.build(
        .base(branch: .local("main")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
      let staged = try #require(result.snapshot.section(.staged))
      #expect(staged.files.map(\.path) == ["a"])
      #expect(staged.truncation == DiffSectionTruncation(outputLimit: limit, firstOmittedPath: "b"))
      #expect(result.patchFailures.isEmpty)
      #expect(staged.unparsedRecordCount == 0)
    }
  }
}
