import CryptoKit
import Foundation
import TerminalCore

/// どの Diff を作るかの指定。`commit` の親は呼び出し側が `git log` から得た値をそのまま渡す
/// (第一親を Adapter が推測で選ばないため。§9.1.2)。
public enum DiffRequest: Sendable, Equatable {
  case commit(hash: String, parentHashes: [String])
  case base(branch: String)
  case branch(name: String)
}

public enum DiffSnapshotBuilderError: Error, Sendable, Equatable {
  case git(GitRunnerError)
  case invalidRevision(String)
  /// merge commit の比較対象は設計書が定めていない (§9.1.2)。
  case unsupportedMergeCommit(parents: [String])
}

public struct DiffSnapshotBuildResult: Sendable {
  public let snapshot: DiffSnapshot
  public let patchFailures: [UnifiedDiffParseFailure]
  public let statusFailures: [GitStatusParseFailure]
  /// untracked のうち中身を読めなかったファイル。件数を黙って捨てない。
  public let unreadableUntrackedPaths: [String]
}

/// §9 の Diff 生成。`GitRunner` の外へ git の呼び出しを漏らさない。
public struct DiffSnapshotBuilder: Sendable {
  private let runner: GitRunner
  private let worktreeRoot: URL
  private let fileReader: FileContentReader

  public init(
    worktreeRoot: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    runner = try GitRunner(
      repositoryDirectory: worktreeRoot,
      processRunner: processRunner,
      executableCandidates: executableCandidates)
    self.worktreeRoot = worktreeRoot
    fileReader = FileContentReader()
  }

  // MARK: - base branch (§9.1.1)

  /// upstream と `origin/HEAD` を観測して渡すだけで、優先順位の判断は `DiffBaseBranchResolver`
  /// が持つ。どちらも「無い」ことが正常系なので、解決できない command 失敗はエラーにしない。
  public func resolveBaseBranch(userSelection: String?) async -> DiffBaseBranch {
    var upstream: String?
    if let parsed = try? await status(untrackedFiles: .normal) {
      upstream = parsed.status.branch?.upstream
    }
    var originHead: String?
    // `origin/HEAD` が無いと `symbolic-ref --quiet` は終了コード 1 で終わる (git 2.50.1 で実測)。
    if let output = try? await run(.originHead()) {
      originHead = GitRefNameList.shortenRemoteRef(output)
    }
    return DiffBaseBranchResolver.resolve(
      userSelection: userSelection, upstream: upstream, originHead: originHead)
  }

  public func refNames() async throws(GitRunnerError) -> GitRefNames {
    GitRefNameList.parse(output: try await runner.run(.listRefs()).stdout)
  }

  public func recentCommits(maxCount: Int) async throws(GitRunnerError) -> [GitCommit] {
    GitLog.parse(output: try await runner.run(.log(maxCount: maxCount)).stdout).commits
  }

  // MARK: - snapshot (§9.3)

  public func build(
    _ request: DiffRequest,
    id: DiffSnapshotID,
    now: Date
  ) async throws(DiffSnapshotBuilderError) -> DiffSnapshotBuildResult {
    let collected = try await collect(request)
    return DiffSnapshotBuildResult(
      snapshot: DiffSnapshot(
        id: id,
        subject: collected.subject,
        createdAt: now,
        sections: collected.sections,
        observation: collected.observation),
      patchFailures: collected.patchFailures,
      statusFailures: collected.statusFailures,
      unreadableUntrackedPaths: collected.unreadableUntrackedPaths)
  }

  /// 開いた snapshot と比べるための再観測。snapshot は作らない (§9.3: Refresh は新規作成)。
  public func observe(
    _ request: DiffRequest
  ) async throws(DiffSnapshotBuilderError) -> DiffSnapshotObservation {
    try await collect(request).observation
  }

  // MARK: -

  private struct Collected {
    let subject: DiffSubject
    let sections: [DiffOriginSection]
    let observation: DiffSnapshotObservation
    let patchFailures: [UnifiedDiffParseFailure]
    let statusFailures: [GitStatusParseFailure]
    let unreadableUntrackedPaths: [String]
  }

  private func collect(
    _ request: DiffRequest
  ) async throws(DiffSnapshotBuilderError) -> Collected {
    switch request {
    case .commit(let hash, let parentHashes):
      return try await collectCommit(hash: hash, parentHashes: parentHashes)
    case .base(let branch):
      return try await collectWorktree(branch: branch) { .base(branch: branch, mergeBase: $0) }
    case .branch(let name):
      return try await collectWorktree(branch: name) { .branch(name: name, mergeBase: $0) }
    }
  }

  private func collectCommit(
    hash: String, parentHashes: [String]
  ) async throws(DiffSnapshotBuilderError) -> Collected {
    let commit = try revision(hash)
    let from: GitRevision
    switch CommitDiffRange.comparison(parentHashes: parentHashes) {
    case .parent(let parent):
      from = try revision(parent)
    case .rootCommit:
      let empty = try await run(.emptyTreeObject()).trimmed
      from = try revision(empty)
    case .unsupportedMergeCommit(let parents):
      throw .unsupportedMergeCommit(parents: parents)
    }
    let patch = try await run(
      .diffPatch(.range(.twoDot(from: from, to: commit))),
      outputLimit: GitRunner.diffPatchOutputLimit)
    let parsed = UnifiedDiffPatch.parse(output: patch)
    let sections = [
      DiffOriginSection(
        origin: .committed, files: parsed.files, unparsedRecordCount: parsed.failures.count)
    ]
    return Collected(
      subject: .commit(hash: hash),
      sections: sections,
      observation: DiffSnapshotObservation(
        headObject: hash, files: observations(of: sections)),
      patchFailures: parsed.failures,
      statusFailures: [],
      unreadableUntrackedPaths: [])
  }

  /// §9.1.3: Base / Branch Diff は commit 済みに加えて staged・unstaged・untracked を含み、
  /// 出所をまたいで hunk をマージしない。
  private func collectWorktree(
    branch: String,
    subject: (String) -> DiffSubject
  ) async throws(DiffSnapshotBuilderError) -> Collected {
    let base = try revision(branch)
    let mergeBase = try await run(.mergeBase(base, .head)).trimmed
    let mergeBaseRevision = try revision(mergeBase)

    var sections: [DiffOriginSection] = []
    var failures: [UnifiedDiffParseFailure] = []
    for (origin, target) in [
      (
        DiffChangeOrigin.committed, GitDiffTarget.range(.twoDot(from: mergeBaseRevision, to: .head))
      ),
      (.staged, .index(against: .head)),
      (.unstaged, .unstaged),
    ] {
      let parsed = UnifiedDiffPatch.parse(
        output: try await run(.diffPatch(target), outputLimit: GitRunner.diffPatchOutputLimit))
      failures += parsed.failures
      sections.append(
        DiffOriginSection(
          origin: origin, files: parsed.files, unparsedRecordCount: parsed.failures.count))
    }

    // untracked をファイル単位で得るため `all` を使う。ignored は含めない (§9.1.3)。
    let statusResult = try await status(untrackedFiles: .all)
    let untracked = synthesizeUntracked(statusResult.status)
    sections.append(DiffOriginSection(origin: .untracked, files: untracked.files))

    return Collected(
      subject: subject(mergeBase),
      sections: sections,
      observation: DiffSnapshotObservation(
        headObject: statusResult.status.branch?.oid, files: observations(of: sections)),
      patchFailures: failures,
      statusFailures: statusResult.failures,
      unreadableUntrackedPaths: untracked.unreadablePaths)
  }

  private func synthesizeUntracked(
    _ status: GitStatus
  ) -> (files: [UnifiedDiffFile], unreadablePaths: [String]) {
    var files: [UnifiedDiffFile] = []
    var unreadable: [String] = []
    for entry in status.entries {
      guard case .untracked(let path) = entry else { continue }
      guard !path.hasSuffix("/") else {
        // `-uall` でも、内部に .git を持つディレクトリは畳まれたまま出る。
        files.append(UntrackedFileDiff.fileWithoutContent(path: path, reason: .notReadable))
        unreadable.append(path)
        continue
      }
      let read = readUntracked(path: path)
      files.append(read.file)
      if !read.isSynthesized { unreadable.append(path) }
    }
    return (files, unreadable)
  }

  /// 全行追加へ合成できたかどうかを、そのまま呼び出し側へ返す。読めなかったものを
  /// 「変更なし」へ丸めない (§12.3)。
  private func readUntracked(path: String) -> (file: UnifiedDiffFile, isSynthesized: Bool) {
    let url = worktreeRoot.appending(path: path)
    guard let result = try? fileReader.read(url: url, confirmation: .confirmed) else {
      return (UntrackedFileDiff.fileWithoutContent(path: path, reason: .notReadable), false)
    }
    switch result.observation {
    case .binary(let byteCount):
      return (
        UntrackedFileDiff.fileWithoutContent(path: path, reason: .binary(byteCount: byteCount)),
        false
      )
    case .text(let byteCount, _):
      guard let text = result.text, text.truncatedAtByteCount == nil else {
        return (
          UntrackedFileDiff.fileWithoutContent(path: path, reason: .tooLarge(byteCount: byteCount)),
          false
        )
      }
      return (UntrackedFileDiff.addedFile(path: path, content: text.content), true)
    }
  }

  private func observations(of sections: [DiffOriginSection]) -> [DiffFileObservation] {
    sections.flatMap { section in
      section.files.map { file in
        DiffFileObservation(
          origin: section.origin,
          path: file.path,
          fingerprint: Self.fingerprint(UnifiedDiffCanonicalText.text(of: file)))
      }
    }
  }

  private static func fingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func status(
    untrackedFiles: GitUntrackedFilesMode
  ) async throws(DiffSnapshotBuilderError) -> GitStatusParseResult {
    GitStatusPorcelainV2.parse(
      output: try await run(.status(untrackedFiles: untrackedFiles)))
  }

  private func run(
    _ command: GitReadCommand,
    outputLimit: Int = GitRunner.defaultOutputLimit
  ) async throws(DiffSnapshotBuilderError) -> String {
    do {
      return try await runner.run(command, outputLimit: outputLimit).stdout
    } catch {
      throw .git(error)
    }
  }

  private func revision(_ value: String) throws(DiffSnapshotBuilderError) -> GitRevision {
    guard let revision = GitRevision(value) else { throw .invalidRevision(value) }
    return revision
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
