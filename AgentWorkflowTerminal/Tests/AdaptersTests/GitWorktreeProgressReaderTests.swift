import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 途中状態の観測 (設計書 §3.4、Issue #355)。どの印がどの種類になるかは git 2.50.1 の実測に
/// よる (`GitWorktreeProgressReader` の doc コメント)。実 git での固定は
/// `GitCloseProgressIntegrationTests`。
@Suite("Close の途中状態の観測 (設計書 §3.4)")
struct GitWorktreeProgressReaderTests {
  private static let administrativeDirectory = "/repo/.git/worktrees/feature-a"
  private static let administrativeFileCases: [([String], Set<WorktreeInProgressOperation>)] = [
    (["rebase-merge"], [.rebase]),
    (["rebase-apply"], [.rebase]),
    (["rebase-apply", "rebase-apply/applying"], [.mailboxApply]),
    (["BISECT_LOG"], [.bisect]),
    (["sequencer"], [.sequence]),
    ([], []),
  ]

  @Test(
    "pseudo ref は git に問い、あれば種類にする",
    arguments: [
      ("MERGE_HEAD", WorktreeInProgressOperation.merge), ("CHERRY_PICK_HEAD", .cherryPick),
      ("REVERT_HEAD", .revert),
    ])
  func classifiesPseudoReferences(
    reference: String, expected: WorktreeInProgressOperation
  )
    async throws
  {
    let result = try await inspect(references: [reference: gitSuccess])

    #expect(result.report.progress == .observed([expected]))
    #expect(result.failure == nil)
  }

  @Test(
    "ref でない印は管理ディレクトリのファイルの有無で見る",
    arguments: administrativeFileCases)
  func classifiesAdministrativeFiles(
    names: [String], expected: Set<WorktreeInProgressOperation>
  ) async throws {
    let result = try await inspect(existingFiles: names)

    #expect(result.report.progress == .observed(expected))
  }

  /// git 2.50.1 実測: 衝突中の `MERGE_HEAD` を空にすると `rev-parse --verify` は rc=1 を返すが、
  /// `git status` は `You have unmerged paths.` のままで、`merge --abort` で消えた。
  @Test("MERGE_HEAD は git が ref として読めなくても、ファイルがあれば途中とみなす")
  func treatsAnUnreadableMergeHeadFileAsInProgress() async throws {
    let result = try await inspect(existingFiles: ["MERGE_HEAD"])

    #expect(result.report.progress == .observed([.merge]))
  }

  /// git 2.50.1 実測: 空の `CHERRY_PICK_HEAD` を git は途中と扱わず (`status` は clean、
  /// `cherry-pick --abort` は rc=128 で失敗)、`reset --hard` でもファイルは残った。拒否すると
  /// 抜け出す手段が git に無い。
  @Test(
    "CHERRY_PICK_HEAD / REVERT_HEAD は git に問い、ファイルだけでは途中とみなさない",
    arguments: ["CHERRY_PICK_HEAD", "REVERT_HEAD"])
  func doesNotTreatAPickHeadFileAloneAsInProgress(name: String) async throws {
    let result = try await inspect(existingFiles: [name])

    #expect(result.report.progress == .observed([]))
  }

  /// 衝突中の連続 cherry-pick は `CHERRY_PICK_HEAD` と `sequencer` を両方持つ (git 2.50.1 実測)。
  @Test("種類が分かっているときは sequence を重ねない")
  func doesNotAddSequenceWhenThePickIsKnown() async throws {
    let result = try await inspect(
      references: ["CHERRY_PICK_HEAD": gitSuccess], existingFiles: ["sequencer"])

    #expect(result.report.progress == .observed([.cherryPick]))
  }

  @Test("管理ディレクトリで git を撃ち、どの ref を問うかを固定する")
  func queriesTheAdministrativeDirectory() async throws {
    let git = gitStub()
    _ = try await inspect(git: git)

    let prefix: [String] = [
      "--no-optional-locks", "-C", Self.administrativeDirectory, "--no-pager",
    ]
    let references = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
    let expected: [[String]] = references.map { prefix + ["rev-parse", "--verify", "--quiet", $0] }
    let actual: [[String]] = await git.arguments
    #expect(actual == expected)
  }

  /// rc=1 は「無い」という答えだが、rc=128 は答えではない (git 2.50.1 実測: 管理ディレクトリが
  /// 無いと `fatal: cannot change to ...`)。
  @Test("問い合わせに失敗したら unknown とし、途中の作業は無いと答えない")
  func reportsUnknownWhenTheQueryFails() async throws {
    let failure = ProcessRunResult(exitCode: 128, stdout: "", stderr: "fatal: boom\n")

    let result = try await inspect(references: ["CHERRY_PICK_HEAD": failure])

    #expect(result.report.progress == .unknown)
    #expect(
      result.failure == .git(.commandFailed(exitCode: 128, stdout: "", stderr: "fatal: boom\n")))
  }

  @Test(
    "HEAD は refs/heads/ を除いた branch 名、rc=1 は detached として読む",
    arguments: [
      (headOnBranch("feat/a"), GitWorktreeProgressReader.Head.branch("feat/a")),
      (.init(exitCode: 0, stdout: "refs/foo/bar\n", stderr: ""), .branch("refs/foo/bar")),
      (gitNotFound, .detached),
    ])
  func readsTheHead(
    result: ProcessRunResult, expected: GitWorktreeProgressReader.Head
  )
    async throws
  {
    #expect(try await reader(git: gitStub(head: result)).head() == expected)
  }

  @Test("ref 名1行として読めない HEAD は失敗にする", arguments: ["", "\n", "refs/heads/a\nb\n"])
  func rejectsUnexpectedHeadOutput(stdout: String) async throws {
    let reader = try reader(git: gitStub(head: .init(exitCode: 0, stdout: stdout, stderr: "")))

    await #expect(throws: GitWorktreeProgressReadError.unexpectedHeadOutput(stdout)) {
      try await reader.head()
    }
  }

  private func inspect(
    git: WorktreeCloseGitStub? = nil, references: [String: ProcessRunResult] = [:],
    existingFiles: [String] = []
  ) async throws -> GitWorktreeProgressInspectionResult {
    let target = try WorktreeCloseHarness.detected(identity: Self.administrativeDirectory)
    let paths = Set(existingFiles.map { "\(Self.administrativeDirectory)/\($0)" })
    return await GitWorktreeProgressInspector(
      target: target, runner: try runner(git: git ?? gitStub(references: references)),
      fileExists: { paths.contains($0) }
    ).inspect()
  }

  private func reader(git: WorktreeCloseGitStub) throws -> GitWorktreeProgressReader {
    GitWorktreeProgressReader(
      runner: try runner(git: git),
      identity: try #require(WorktreeIdentity(rawValue: Self.administrativeDirectory)),
      fileExists: { _ in false })
  }

  private func runner(git: WorktreeCloseGitStub) throws -> GitRunner {
    try GitRunner(
      repositoryDirectory: URL(fileURLWithPath: Self.administrativeDirectory),
      processRunner: git, executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: [:], isExecutableFile: { _ in true })
  }
}
