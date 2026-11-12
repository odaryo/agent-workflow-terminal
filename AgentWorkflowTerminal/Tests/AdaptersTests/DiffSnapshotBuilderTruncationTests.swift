import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§7.2・§9.1.3 Diff snapshot の部分表示")
struct DiffSnapshotBuilderTruncationTests {
  private let limit = 512

  @Test("§7.2 staged の打ち切りを他区分へ広げず捨てたレコードを解析失敗にしない")
  func truncatesOnlyStagedSection() async throws {
    let spy = try makeSpy()
    let builder = try makeBuilder(spy)
    let result = try await builder.build(
      .base(branch: .local("main")), id: DiffSnapshotID(rawValue: UUID()), now: Date())
    let staged = try #require(result.snapshot.section(.staged))
    #expect(staged.files.map(\.path) == ["bin.dat", "del.txt"])
    let expectedTruncation = DiffSectionTruncation(
      outputLimit: limit, firstOmittedPath: "keep.txt")
    #expect(staged.truncation == expectedTruncation)
    #expect(result.patchFailures.isEmpty)
    #expect(result.snapshot.sections.allSatisfy { $0.unparsedRecordCount == 0 })
    for origin in [DiffChangeOrigin.committed, .unstaged] {
      let section = try #require(result.snapshot.section(origin))
      #expect(section.truncation == nil)
      #expect(section.files.map(\.path) == ["bin.dat", "del.txt", "keep.txt", "newname.txt"])
    }
    let untracked = try #require(result.snapshot.section(.untracked))
    #expect(untracked.truncation == nil)
    #expect(untracked.files.map(\.path) == ["untracked.txt"])
    #expect(await spy.truncatingLimits == [limit, limit, limit])
  }

  @Test("§7.2 Commit Diff の committed 区分にも打ち切りを付ける")
  func truncatesCommitSection() async throws {
    let spy = try makeSpy(origin: .committed)
    let result = try await makeBuilder(spy).build(
      .commit(hash: "abc", parentHashes: ["def"]),
      id: DiffSnapshotID(rawValue: UUID()), now: Date())
    let section = try #require(result.snapshot.section(.committed))
    #expect(section.files.map(\.path) == ["bin.dat", "del.txt"])
    let expectedTruncation = DiffSectionTruncation(
      outputLimit: limit, firstOmittedPath: "keep.txt")
    #expect(section.truncation == expectedTruncation)
    #expect(result.patchFailures.isEmpty)
    #expect(section.unparsedRecordCount == 0)
    #expect(await spy.truncatingLimits == [limit])
  }

  @Test("§12.3 最初のレコード内で打ち切られても差分無しにしない")
  func preservesTruncationWithNoVisibleFiles() async throws {
    let edge = try DiffTruncationFixtures.edge()
    let cut = try #require(edge.range(of: "+café"))
    let spy = BuilderTruncationSpy(
      origin: .committed, partialPatch: String(edge[..<cut.upperBound]), completedPatch: "")
    let result = try await makeBuilder(spy).build(
      .commit(hash: "abc", parentHashes: ["def"]),
      id: DiffSnapshotID(rawValue: UUID()), now: Date())
    let section = try #require(result.snapshot.section(.committed))
    #expect(section.files.isEmpty)
    let expectedTruncation = DiffSectionTruncation(
      outputLimit: limit, firstOmittedPath: "café.txt")
    #expect(section.truncation == expectedTruncation)
    #expect(!result.snapshot.isEmpty)
    #expect(result.patchFailures.isEmpty)
    #expect(section.unparsedRecordCount == 0)
  }

  @Test("§9.3 observe は打ち切りで失敗せず build と同じ表示ファイルだけを観測する")
  func observesOnlyVisibleFiles() async throws {
    let builder = try makeBuilder(makeSpy())
    let request = DiffRequest.base(branch: .local("main"))
    let result = try await builder.build(
      request, id: DiffSnapshotID(rawValue: UUID()), now: Date())
    let observed = try await builder.observe(request)
    let expected = result.snapshot.sections.flatMap { section in
      section.files.map { "\(section.origin):\($0.path)" }
    }
    #expect(observed.files.map { "\($0.origin):\($0.path)" } == expected)
    #expect(observed == result.snapshot.observation)
    #expect(observed.files.filter { $0.origin == .staged }.map(\.path) == ["bin.dat", "del.txt"])
    #expect(!observed.files.contains { $0.origin == .staged && $0.path == "keep.txt" })
  }

  private func makeSpy(origin: DiffChangeOrigin = .staged) throws -> BuilderTruncationSpy {
    let patch = try DiffTruncationFixtures.cached()
    let cut = try #require(patch.range(of: "+l2 sta"))
    return BuilderTruncationSpy(
      origin: origin, partialPatch: String(patch[..<cut.upperBound]), completedPatch: patch)
  }

  private func makeBuilder(_ spy: BuilderTruncationSpy) throws -> DiffSnapshotBuilder {
    try DiffSnapshotBuilder(
      worktreeRoot: URL(fileURLWithPath: "/repo"), processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")], diffPatchOutputLimit: limit)
  }
}

private actor BuilderTruncationSpy: ProcessRunning {
  let origin: DiffChangeOrigin
  let partialPatch: String
  let completedPatch: String
  private(set) var truncatingLimits: [Int] = []

  init(origin: DiffChangeOrigin, partialPatch: String, completedPatch: String) {
    self.origin = origin
    self.partialPatch = partialPatch
    self.completedPatch = completedPatch
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    if arguments.contains("--patch"), matchesOrigin(arguments) {
      throw .outputLimitExceeded(limit: outputLimit)
    }
    let stdout: String
    if arguments.contains("merge-base") {
      stdout = String(repeating: "a", count: 40) + "\n"
    } else if arguments.contains("status") {
      stdout =
        "# branch.oid " + String(repeating: "a", count: 40)
        + "\0# branch.head feature\0? untracked.txt\0"
    } else {
      stdout = arguments.contains("--patch") ? completedPatch : ""
    }
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }

  func runTruncatingAtOutputLimit(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunOutput {
    truncatingLimits.append(outputLimit)
    if matchesOrigin(arguments) {
      return .truncated(stdout: partialPatch, stderr: "", limit: outputLimit)
    }
    return .completed(ProcessRunResult(exitCode: 0, stdout: completedPatch, stderr: ""))
  }

  private func matchesOrigin(_ arguments: [String]) -> Bool {
    switch origin {
    case .staged: arguments.contains("--cached")
    case .committed: arguments.contains { $0.contains("..") }
    default: false
    }
  }
}
