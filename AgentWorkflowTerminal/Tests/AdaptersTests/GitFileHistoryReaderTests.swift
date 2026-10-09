import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// git は実行せず、`ProcessRunning` の mock に渡る argv・timeout・出力上限を確かめる。
/// 実 git での挙動は `GitFileHistoryIntegrationTests` が固定する。
@Suite("§7.3 / §17.1 ファイル履歴・過去版・blame の読み取り")
struct GitFileHistoryReaderTests {
  private static let commit = String(repeating: "c", count: 40)
  private static let blobID = String(repeating: "b", count: 40)

  @Test("履歴は上限より1件多く求め、超えた分で「さらに読む」を判定する")
  func requestsOneMoreThanLimit() async throws {
    let record = "\(Self.commit)\0ccccccc\0\0a\01767225600\0s\0\nM\0a b.txt\0"
    let spy = ScriptedGitProcess(outputs: [String(repeating: record, count: 3)])
    let page = try await makeReader(spy).history(path: "a b.txt", limit: 2)

    #expect(page.records.count == 2)
    #expect(page.hasMore)
    let call = try #require(await spy.calls.first)
    #expect(
      call.arguments.dropFirst(4) == [
        "log", "-z", "--no-show-signature", "--encoding=UTF-8", "--find-renames",
        "--diff-merges=first-parent", "--name-status", "--root",
        "--format=" + GitFileHistory.format, "--follow", "--max-count=3", "HEAD", "--",
        ":(literal)a b.txt",
      ])
    #expect(call.timeout == GitFileHistoryReader.historyTimeout)
  }

  @Test("上限ちょうどの件数なら「さらに読む」を出さない")
  func noMoreWhenWithinLimit() async throws {
    let record = "\(Self.commit)\0ccccccc\0\0a\01767225600\0s\0\nM\0a\0"
    let spy = ScriptedGitProcess(outputs: [String(repeating: record, count: 2)])
    let page = try await makeReader(spy).history(path: "a", limit: 2)

    #expect(page.records.count == 2)
    #expect(!page.hasMore)
  }

  @Test("blame は working tree に対し、pathspec の magic を付けずに渡す")
  func blameArguments() async throws {
    let spy = ScriptedGitProcess(outputs: [""])
    _ = try await makeReader(spy).blame(path: "src/a*.txt")
    let call = try #require(await spy.calls.first)

    #expect(
      call.arguments.dropFirst(4) == [
        "-c", "core.quotePath=false", "blame", "--porcelain", "--no-root", "--encoding=UTF-8",
        "--", "src/a*.txt",
      ])
    #expect(call.timeout == GitFileHistoryReader.blameTimeout)
    #expect(call.outputLimit == GitFileHistoryReader.blameOutputLimit)
  }

  @Test("過去版は ls-tree で種別とサイズを確かめてから、blob をサイズに見合う上限で読む")
  func readsBlobWithSizedLimit() async throws {
    let spy = ScriptedGitProcess(outputs: [
      "100644 blob \(Self.blobID)       6\tsrc/a.txt\0", "hello\n",
    ])
    let version = try await makeReader(spy).version(commitID: Self.commit, path: "src/a.txt")
    let calls = await spy.calls

    #expect(
      calls.map { Array($0.arguments.dropFirst(4)) } == [
        ["ls-tree", "-z", "--long", Self.commit, "--", ":(literal)src/a.txt"],
        ["cat-file", "blob", Self.blobID],
      ])
    #expect(calls.last?.outputLimit == 6 + (64 << 10))
    // mock の OID は内容と一致しないので、置換が起きた内容と同じくバイナリになる。
    #expect(version == .content(try #require(binaryResult(byteCount: 6))))
  }

  @Test("絶対上限を超える過去版は blob を読まない")
  func refusesBlobAboveAbsoluteMaximum() async throws {
    let spy = ScriptedGitProcess(outputs: ["100644 blob \(Self.blobID) 2000\ta\0"])
    let thresholds = FileViewThresholds(
      maximumByteCount: 10, maximumLineCount: 10, absoluteMaximumByteCount: 1_000)
    let version = try await makeReader(spy).version(
      commitID: Self.commit, path: "a", thresholds: thresholds, confirmation: .confirmed)

    #expect(version == .exceedsAbsoluteMaximum(byteCount: 2_000, maximum: 1_000))
    #expect(await spy.calls.count == 1)
  }

  @Test(
    "symlink・submodule・不在は本文を読まない",
    arguments: [
      ("120000 blob \(blobID) 3\ta\0", GitFileVersion.symbolicLink),
      ("160000 commit \(blobID)       -\ta\0", .submodule),
      ("", .absent),
      ("100644 blob \(blobID) 3\tab\0", .absent),
    ])
  func doesNotReadNonRegularFiles(listing: String, expected: GitFileVersion) async throws {
    let spy = ScriptedGitProcess(outputs: [listing])
    let version = try await makeReader(spy).version(commitID: Self.commit, path: "a")

    #expect(version == expected)
    #expect(await spy.calls.count == 1)
  }

  @Test("Diff は rename の前後のパスを両方 pathspec に入れ、merge は第1親と比べる")
  func diffArguments() async throws {
    let spy = ScriptedGitProcess(outputs: [""])
    let parents = [String(repeating: "1", count: 40), String(repeating: "2", count: 40)]
    let diff = try await makeReader(spy).diff(
      commitID: Self.commit, parentIDs: parents,
      change: GitFileHistoryChange(kind: .renamed(score: 90), path: "new", previousPath: "old"))
    let call = try #require(await spy.calls.first)

    #expect(diff.base == .firstParentOfMerge(parents[0], parentCount: 2))
    #expect(
      call.arguments.suffix(4) == [
        parents[0] + ".." + Self.commit, "--", ":(literal)new", ":(literal)old",
      ])
    #expect(call.outputLimit == GitRunner.diffPatchOutputLimit)
  }

  @Test("root commit の Diff は空 tree と比べる")
  func rootDiffUsesEmptyTree() async throws {
    let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    let spy = ScriptedGitProcess(outputs: [emptyTree + "\n", ""])
    let diff = try await makeReader(spy).diff(
      commitID: Self.commit, parentIDs: [],
      change: GitFileHistoryChange(kind: .added, path: "a", previousPath: nil))
    let calls = await spy.calls

    #expect(diff.base == .emptyTree)
    #expect(calls.first?.arguments.dropFirst(4) == ["hash-object", "-t", "tree", "/dev/null"])
    #expect(
      calls.last?.arguments.suffix(3) == [emptyTree + ".." + Self.commit, "--", ":(literal)a"])
  }

  @Test("git へ渡せないパスと commit ID を拒否する")
  func rejectsInvalidInputs() async throws {
    let reader = try makeReader(ScriptedGitProcess(outputs: []))
    await #expect(throws: GitFileHistoryError.invalidPath("")) {
      try await reader.history(path: "")
    }
    await #expect(throws: GitFileHistoryError.invalidPath("a\nb")) {
      try await reader.history(path: "a\nb")
    }
    await #expect(throws: GitFileHistoryError.invalidCommitID("HEAD")) {
      try await reader.version(commitID: "HEAD", path: "a")
    }
  }

  private func binaryResult(byteCount: Int) -> FileContentReadResult? {
    let observation = FileViewObservation.binary(byteCount: byteCount)
    return FileContentReadResult(
      observation: observation, decision: FileOpenDecision.decide(observation: observation),
      text: nil)
  }

  private func makeReader(_ spy: ScriptedGitProcess) throws -> GitFileHistoryReader {
    try GitFileHistoryReader(
      worktreeRoot: URL(fileURLWithPath: "/repo"), processRunner: spy,
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")])
  }
}

private actor ScriptedGitProcess: ProcessRunning {
  struct Call: Sendable {
    let arguments: [String]
    let timeout: Duration
    let outputLimit: Int
  }
  private(set) var calls: [Call] = []
  private var outputs: [String]

  init(outputs: [String]) { self.outputs = outputs }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(.init(arguments: arguments, timeout: timeout, outputLimit: outputLimit))
    let stdout = outputs.isEmpty ? "" : outputs.removeFirst()
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }
}
