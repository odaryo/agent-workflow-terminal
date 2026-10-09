import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// `GitWorktreeDetectorIntegrationTests` と同じ `AWT_GIT_INTEGRATION` で有効にする。
private let isGitIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1"

/// 実 git に対して §7.3 のファイル履歴・過去版・blame を固定する。fixture では「rename を
/// 挟んだ続きの読み込み」や「過去版のバイト列が元と一致するか」を確かめられないため。
@Suite(
  "§7.3 実 git でのファイル履歴・過去版・blame",
  .enabled(if: isGitIntegrationEnabled)
)
struct GitFileHistoryIntegrationTests {
  private static let oldPath = "src/old name ä.txt"
  private static let newPath = "src/new name é.txt"

  @Test("rename を挟んだ履歴を、各 commit 時点のパスとともに返す", .timeLimit(.minutes(1)))
  func followsRename() async throws {
    try await withGitRepository { repository in
      let ids = try await makeRenamedHistory(repository)
      let reader = try makeReader(repository)

      let page = try await reader.history(path: Self.newPath)
      let entries = page.entries

      #expect(page.records.count == entries.count)
      #expect(!page.hasMore)
      #expect(entries.map(\.commitID) == [ids.afterRename, ids.rename, ids.beforeRename, ids.root])
      #expect(
        entries.map { $0.changes.map(\.path) } == [
          [Self.newPath], [Self.newPath], [Self.oldPath], [Self.oldPath],
        ])
      let rename = try #require(entries.dropFirst().first?.changes.first)
      #expect(rename.previousPath == Self.oldPath)
      guard case .renamed = rename.kind else {
        Issue.record("rename の commit が rename として出ていない: \(rename.kind)")
        return
      }
      #expect(entries.first?.authorName == "作者 Tab\tName")
      #expect(entries.first?.summary == "after\trename 変更")
    }
  }

  /// `--skip` では rename より前へ進めないため、件数を広げた読み直しで続きを取る。
  @Test("続きの読み込みは rename の前の commit まで届く", .timeLimit(.minutes(1)))
  func pagesAcrossRename() async throws {
    try await withGitRepository { repository in
      let ids = try await makeRenamedHistory(repository)
      let reader = try makeReader(repository)

      let first = try await reader.history(path: Self.newPath, limit: 2)
      let second = try await reader.history(path: Self.newPath, limit: 4)

      #expect(first.entries.map(\.commitID) == [ids.afterRename, ids.rename])
      #expect(first.hasMore)
      #expect(
        second.entries.map(\.commitID) == [
          ids.afterRename, ids.rename, ids.beforeRename, ids.root,
        ])
      #expect(!second.hasMore)
    }
  }

  @Test("blame の行から移る1件は、rename の前後を渡すと rename として出る", .timeLimit(.minutes(1)))
  func readsSingleEntry() async throws {
    try await withGitRepository { repository in
      let ids = try await makeRenamedHistory(repository)
      let reader = try makeReader(repository)

      let entry = try #require(
        try await reader.entry(commitID: ids.rename, paths: [Self.newPath, Self.oldPath]))

      #expect(entry.commitID == ids.rename)
      #expect(
        entry.changes == [
          GitFileHistoryChange(
            kind: .renamed(score: try #require(renameScore(entry))), path: Self.newPath,
            previousPath: Self.oldPath)
        ])
    }
  }

  @Test("root commit の Diff は空 tree と比べ、全行が追加になる", .timeLimit(.minutes(1)))
  func rootCommitDiff() async throws {
    try await withGitRepository { repository in
      let ids = try await makeRenamedHistory(repository)
      let reader = try makeReader(repository)
      let root = try #require(
        try await reader.history(path: Self.newPath).entries.last)

      let diff = try await reader.diff(
        commitID: ids.root, parentIDs: root.parentIDs, change: try #require(root.changes.first))

      #expect(root.parentIDs.isEmpty)
      #expect(diff.base == .emptyTree)
      #expect(diff.failures.isEmpty)
      let file = try #require(diff.files.first)
      #expect(diff.files.count == 1)
      #expect(file.changeKind == .added)
      #expect(file.path == Self.oldPath)
      guard case .hunks(let hunks) = file.content else {
        Issue.record("hunk が無い: \(file.content)")
        return
      }
      #expect(hunks.flatMap(\.lines).map(\.kind) == [.added, .added])
    }
  }

  /// 履歴の取得側 (`--follow`) は merge を既定で出さないので、`--diff-merges=first-parent`
  /// で出したものと、Diff 側の比較対象 (第1親) が同じ変更を指すことを確かめる。
  @Test("merge commit は履歴に1回だけ出て、Diff は第1親との差分になる", .timeLimit(.minutes(1)))
  func mergeCommitUsesFirstParent() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("one\ntwo\nthree\n", to: root, "m.txt")
      try await commit(repository, "base")
      try await repository.git(["checkout", "-q", "-b", "side"])
      try write("one\ntwo\nthree side\n", to: root, "m.txt")
      try await commit(repository, "side")
      try await repository.git(["checkout", "-q", "main"])
      try write("one main\ntwo\nthree\n", to: root, "m.txt")
      try await commit(repository, "main")
      try await repository.git(["merge", "-q", "--no-ff", "-m", "merge side", "side"])
      let reader = try makeReader(repository)

      let entries = try await reader.history(path: "m.txt").entries
      let merge = try #require(entries.first)
      let diff = try await reader.diff(
        commitID: merge.commitID, parentIDs: merge.parentIDs,
        change: try #require(merge.changes.first))

      #expect(entries.map(\.summary) == ["merge side", "main", "side", "base"])
      #expect(merge.isMerge)
      #expect(diff.base == .firstParentOfMerge(merge.parentIDs[0], parentCount: 2))
      guard case .hunks(let hunks) = try #require(diff.files.first).content else {
        Issue.record("hunk が無い")
        return
      }
      let changed = hunks.flatMap(\.lines).filter { $0.kind != .context }.map(\.text)
      #expect(changed == ["three", "three side"])
    }
  }

  @Test("blame は未commit の行と root commit の境界を区別する", .timeLimit(.minutes(1)))
  func blameMarksUncommittedLines() async throws {
    try await withGitRepository { repository in
      let ids = try await makeRenamedHistory(repository)
      try write("r1\nr2 after\nuncommitted\n", to: repository.mainWorktree, Self.newPath)
      let reader = try makeReader(repository)

      let blame = try await reader.blame(path: Self.newPath)

      #expect(blame.failures.isEmpty)
      #expect(blame.lines.map(\.content) == ["r1", "r2 after", "uncommitted"])
      #expect(blame.lines.map(\.commitID).prefix(2) == [ids.root, ids.afterRename])
      #expect(blame.lines.map { blame.commit(for: $0)?.isUncommitted } == [false, false, true])
      #expect(blame.commit(for: blame.lines[0])?.isBoundary == true)
      #expect(blame.lines.map(\.path) == [Self.oldPath, Self.newPath, Self.newPath])
      #expect(blame.commit(for: blame.lines[1])?.authorName == "作者 Tab\tName")
    }
  }

  @Test("過去版の本文は元のバイト列と一致し、rename 前のパスで読める", .timeLimit(.minutes(1)))
  func readsPastVersionAtOldPath() async throws {
    try await withGitRepository { repository in
      let ids = try await makeRenamedHistory(repository)
      let reader = try makeReader(repository)

      let past = try await reader.version(commitID: ids.beforeRename, path: Self.oldPath)
      let missing = try await reader.version(commitID: ids.beforeRename, path: Self.newPath)

      #expect(text(of: past) == "r1\nr2 before\n")
      #expect(missing == .absent)
    }
  }

  /// `"` を含むパスは `ls-tree --format` だと `-z` でも引用されて一致しなくなる (実測)。
  @Test("glob 文字・引用符を含むファイル名は、そのファイルだけを指す", .timeLimit(.minutes(1)))
  func treatsPathLiterally() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write("star\n", to: root, "a*.txt")
      try write("other\n", to: root, "ab.txt")
      try write("quoted\n", to: root, "q\"uote.txt")
      try await commit(repository, "both")
      try write("other 2\n", to: root, "ab.txt")
      try await commit(repository, "only ab")
      let reader = try makeReader(repository)

      let entries = try await reader.history(path: "a*.txt").entries
      let head = try #require(entries.first)
      let version = try await reader.version(commitID: head.commitID, path: "a*.txt")
      let blame = try await reader.blame(path: "a*.txt")

      #expect(entries.map(\.summary) == ["both"])
      #expect(text(of: version) == "star\n")
      #expect(
        text(of: try await reader.version(commitID: head.commitID, path: "q\"uote.txt"))
          == "quoted\n")
      #expect(blame.lines.map(\.content) == ["star"])
    }
  }

  @Test("過去版がバイナリ・不正 UTF-8 なら本文を出さない", .timeLimit(.minutes(1)))
  func pastBinaryVersions() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])
      let invalid = Data("ok ".utf8) + Data([0xFF, 0xFE]) + Data("\n".utf8)
      try binary.write(to: root.appending(path: "img.bin"))
      try invalid.write(to: root.appending(path: "latin.txt"))
      try await commit(repository, "binary")
      let reader = try makeReader(repository)
      let head = try #require(
        try await reader.history(path: "img.bin").entries.first)

      let image = try await reader.version(commitID: head.commitID, path: "img.bin")
      let latin = try await reader.version(commitID: head.commitID, path: "latin.txt")

      #expect(observation(of: image) == .binary(byteCount: binary.count))
      #expect(observation(of: latin) == .binary(byteCount: invalid.count))
      #expect(text(of: image) == nil)
    }
  }

  @Test("絶対上限を超える過去版と symlink は本文を読まない", .timeLimit(.minutes(1)))
  func refusesOversizedAndSymlink() async throws {
    try await withGitRepository { repository in
      let root = repository.mainWorktree
      try write(String(repeating: "x", count: 2_000), to: root, "big.txt")
      try FileManager.default.createSymbolicLink(
        atPath: root.appending(path: "link").path, withDestinationPath: "big.txt")
      try await commit(repository, "big and link")
      let reader = try makeReader(repository)
      let head = try #require(
        try await reader.history(path: "big.txt").entries.first)
      let thresholds = FileViewThresholds(
        maximumByteCount: 100, maximumLineCount: 10, absoluteMaximumByteCount: 1_000)

      let big = try await reader.version(
        commitID: head.commitID, path: "big.txt", thresholds: thresholds,
        confirmation: .confirmed)
      let link = try await reader.version(commitID: head.commitID, path: "link")

      #expect(big == .exceedsAbsoluteMaximum(byteCount: 2_000, maximum: 1_000))
      #expect(link == .symbolicLink)
    }
  }

  // MARK: -

  private struct RenamedHistory {
    let root: String
    let beforeRename: String
    let rename: String
    let afterRename: String
  }

  /// root → 変更 → rename (内容は同一) → rename 後の変更。author と summary に空白・タブ・
  /// 非 ASCII を入れる。`withGitRepository` は空の commit を1つ作るので、本物の root commit に
  /// するため orphan branch から始める。
  private func makeRenamedHistory(_ repository: GitTestRepository) async throws -> RenamedHistory {
    let root = repository.mainWorktree
    try await repository.git(["checkout", "-q", "--orphan", "history"])
    try FileManager.default.createDirectory(
      at: root.appending(path: "src"), withIntermediateDirectories: true)
    try write("r1\nr2\n", to: root, Self.oldPath)
    let rootID = try await commit(repository, "root: 初回")
    try write("r1\nr2 before\n", to: root, Self.oldPath)
    let before = try await commit(repository, "before rename")
    try await repository.git(["mv", Self.oldPath, Self.newPath])
    let rename = try await commit(repository, "rename")
    try write("r1\nr2 after\n", to: root, Self.newPath)
    let after = try await commit(
      repository, "after\trename 変更", author: "作者 Tab\tName <tab@example.invalid>")
    return RenamedHistory(root: rootID, beforeRename: before, rename: rename, afterRename: after)
  }

  @discardableResult
  private func commit(
    _ repository: GitTestRepository, _ message: String,
    author: String = "awt <awt@example.invalid>"
  ) async throws -> String {
    try await repository.git(["add", "-A"])
    try await repository.git(["commit", "-q", "--author", author, "-m", message])
    return try await headID(repository)
  }

  private func headID(_ repository: GitTestRepository) async throws -> String {
    let runner = try GitRunner(
      repositoryDirectory: repository.mainWorktree, processRunner: FoundationProcessRunner())
    let output = try await runner.run(GitReadCommand(arguments: ["rev-parse", "HEAD"])).stdout
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func makeReader(_ repository: GitTestRepository) throws -> GitFileHistoryReader {
    try GitFileHistoryReader(
      worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
  }

  private func renameScore(_ entry: GitFileHistoryEntry) -> Int? {
    guard case .renamed(let score) = entry.changes.first?.kind else { return nil }
    return score
  }

  private func text(of version: GitFileVersion) -> String? {
    guard case .content(let result) = version else { return nil }
    return result.text?.content
  }

  private func observation(of version: GitFileVersion) -> FileViewObservation? {
    guard case .content(let result) = version else { return nil }
    return result.observation
  }

  private func write(_ contents: String, to root: URL, _ name: String) throws {
    try contents.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
  }
}
