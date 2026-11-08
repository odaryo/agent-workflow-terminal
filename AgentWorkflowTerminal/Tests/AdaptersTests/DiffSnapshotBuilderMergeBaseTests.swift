import Adapters
import Foundation
import TerminalCore
import Testing

@Suite("§9.1.4 merge-base の失敗判定")
struct DiffSnapshotBuilderMergeBaseTests {
  @Test("stderr に何か出た終了コード 1 は共通祖先が無いと断定しない")
  func doesNotAssertMissingMergeBaseWhenGitWarns() async throws {
    let graftFile = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString).appending(path: "info/grafts").path
    try #require(!FileManager.default.fileExists(atPath: graftFile))
    let builder = try DiffSnapshotBuilder(
      worktreeRoot: URL(fileURLWithPath: "/repo"),
      processRunner: MergeBaseWarningRunner(graftFile: graftFile),
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")])

    await #expect(
      throws: DiffSnapshotBuilderError.mergeBaseUnresolved(
        branch: "ambiguous", reason: .gitReported(stderr: "warning: something"))
    ) {
      try await builder.build(
        .branch(name: .local("ambiguous")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
    }
  }
}

private actor MergeBaseWarningRunner: ProcessRunning {
  let graftFile: String

  init(graftFile: String) {
    self.graftFile = graftFile
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    if arguments.contains("merge-base") {
      return ProcessRunResult(exitCode: 1, stdout: "", stderr: "warning: something")
    }
    if arguments.contains("--is-shallow-repository") {
      return ProcessRunResult(exitCode: 0, stdout: "false\n\(graftFile)\n", stderr: "")
    }
    return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
  }
}
