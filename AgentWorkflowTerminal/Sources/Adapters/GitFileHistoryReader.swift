import Foundation
import TerminalCore

public enum GitFileHistoryError: Error, Sendable, Equatable {
  case git(GitRunnerError)
  /// git へ渡せないパス (`GitPathspec` の制約: 空・先頭 `-`・NUL・改行)。
  case invalidPath(String)
  case invalidCommitID(String)
  /// `ls-tree` の出力を解釈できなかった。
  case unexpectedTreeEntry(String)
}

public struct GitFileHistoryPage: Sendable, Equatable {
  public let records: [GitFileHistoryRecord]
  /// 上限より古い commit がまだある。`git log --skip` では続きを取れないので、呼び出し側は
  /// 上限を広げて読み直す (`GitFileHistoryReader.history` の注記)。
  public let hasMore: Bool

  public var entries: [GitFileHistoryEntry] {
    GitFileHistoryParseResult(records: records).entries
  }
}

public enum GitFileVersion: Sendable, Equatable {
  case content(FileContentReadResult)
  /// その commit にこのパスが無い (この commit で削除された場合など)。
  case absent
  /// 現在のファイルと同じく、通常ファイルでないものは本文を読まない (§7.2)。
  case symbolicLink
  case submodule
  /// 絶対上限を超える過去版は本文を取得しない。`ProcessRunner` は出力上限で打ち切らずに
  /// エラーにするので、現在のファイルのように「先頭だけを表示」できないため。
  case exceedsAbsoluteMaximum(byteCount: Int, maximum: Int)
}

public struct GitFileHistoryDiff: Sendable {
  public let base: FileHistoryDiffBase
  public let files: [UnifiedDiffFile]
  public let failures: [UnifiedDiffParseFailure]
}

/// Code Viewer のファイル単位の履歴・過去版・blame (設計書 §7.3 / §17.1)。読み取りだけを行う。
public struct GitFileHistoryReader: Sendable {
  public static let pageSize = 200
  /// `--follow` は rename を探すために全 commit の差分を見るので、古い大きな repository では
  /// 既定の 30 秒を超え得る。
  public static let historyTimeout = Duration.seconds(60)
  public static let blameTimeout = Duration.seconds(120)
  /// blame を出すのは §7.2 で本文を展開するファイル (1 MiB / 50,000 行以下) に限る。porcelain
  /// は1行あたり OID と行番号 (約 50 バイト) を足し、commit ごとのメタデータ (数百バイト) を
  /// 初出時に1回出すので、最悪でも 1 MiB + 50,000 × (50 + 数百) バイトに収まる。
  public static let blameOutputLimit = 32 << 20
  /// `cat-file blob` の上限は blob のサイズに、stderr の分としてこれを足したもの。
  private static let blobOutputMargin = 64 << 10

  private let runner: GitRunner

  public init(
    worktreeRoot: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    runner = try GitRunner(
      repositoryDirectory: worktreeRoot, processRunner: processRunner,
      executableCandidates: executableCandidates)
  }

  /// HEAD から辿ったファイルの履歴の、新しい方から `limit` 件。
  ///
  /// 続きは `--skip` ではなく `limit` を広げた読み直しで取る。`--follow` は rename を、その
  /// commit を**出力するときに**検出してパスを切り替えるので、`--skip` で rename の commit を
  /// 読み飛ばすと古いパスへ切り替わらず、それより前の履歴が1件も出ない (2.50.1 / 2.55.0 で
  /// 実測: rename の前に 2 件ある履歴で `--max-count=2 --skip=4` が空を返した)。
  public func history(
    path: String, limit: Int = Self.pageSize
  ) async throws(GitFileHistoryError) -> GitFileHistoryPage {
    let pathspec = try literalPathspec(path)
    let output = try await run(
      .fileHistory(pathspec: pathspec, maxCount: max(limit, 1) + 1),
      timeout: Self.historyTimeout)
    let records = GitFileHistory.parse(output: output).records
    return GitFileHistoryPage(records: Array(records.prefix(limit)), hasMore: records.count > limit)
  }

  /// 1 commit 分の履歴項目。blame の行から、読み込み済みの履歴に無い commit へ移るときに使う。
  /// `paths` には rename の前後を両方渡す (片方だけでは rename を検出できず、追加に見える)。
  public func entry(
    commitID: String, paths: [String]
  ) async throws(GitFileHistoryError) -> GitFileHistoryEntry? {
    let commit = try revision(commitID)
    var pathspecs: [GitPathspec] = []
    for path in paths { pathspecs.append(try literalPathspec(path)) }
    let output = try await run(
      .fileHistoryEntry(commit: commit, pathspecs: pathspecs), timeout: Self.historyTimeout)
    return GitFileHistory.parse(output: output).entries.first
  }

  /// `path` はその commit 時点のパス (`GitFileHistoryChange.path`)。
  public func version(
    commitID: String,
    path: String,
    thresholds: FileViewThresholds = .default,
    confirmation: FileOpenConfirmation = .notConfirmed
  ) async throws(GitFileHistoryError) -> GitFileVersion {
    let commit = try revision(commitID)
    let pathspec = try literalPathspec(path)
    let listing = try await run(.treeEntry(commit: commit, pathspec: pathspec))
    guard let entry = try treeEntry(in: listing, path: path) else { return .absent }
    switch entry.mode {
    case "120000": return .symbolicLink
    case "160000": return .submodule
    default: break
    }
    guard entry.type == "blob", let byteCount = entry.size, let object = GitRevision(entry.object)
    else { throw .unexpectedTreeEntry(entry.raw) }
    guard byteCount <= thresholds.absoluteMaximumByteCount else {
      return .exceedsAbsoluteMaximum(
        byteCount: byteCount, maximum: thresholds.absoluteMaximumByteCount)
    }
    let stdout = try await run(.blob(object), outputLimit: byteCount + Self.blobOutputMargin)
    return .content(
      GitBlobContent.classify(
        stdout: stdout, byteCount: byteCount, objectID: entry.object, thresholds: thresholds,
        confirmation: confirmation))
  }

  /// その commit がそのファイルに入れた変更。merge commit は第1親と比べる (§7.3)。
  public func diff(
    commitID: String, parentIDs: [String], change: GitFileHistoryChange
  ) async throws(GitFileHistoryError) -> GitFileHistoryDiff {
    let commit = try revision(commitID)
    let base = FileHistoryDiffBase.base(parentIDs: parentIDs)
    let from: GitRevision
    if let parent = base.comparedParentID {
      from = try revision(parent)
    } else {
      from = try revision(
        try await run(.emptyTreeObject()).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var pathspecs = [try literalPathspec(change.path)]
    if let previous = change.previousPath { pathspecs.append(try literalPathspec(previous)) }
    let patch = try await run(
      .diffPatch(.range(.twoDot(from: from, to: commit)), pathspec: pathspecs),
      outputLimit: GitRunner.diffPatchOutputLimit)
    let parsed = UnifiedDiffPatch.parse(output: patch)
    return GitFileHistoryDiff(base: base, files: parsed.files, failures: parsed.failures)
  }

  /// working tree の内容に対する blame。未 commit の行を含む。
  public func blame(path: String) async throws(GitFileHistoryError) -> GitBlameParseResult {
    guard let file = GitPathspec(path) else { throw .invalidPath(path) }
    let output = try await run(
      .blame(path: file), timeout: Self.blameTimeout, outputLimit: Self.blameOutputLimit)
    return GitBlamePorcelain.parse(output: output)
  }

  // MARK: -

  private struct TreeEntry {
    let mode: String
    let type: String
    let object: String
    let size: Int?
    let raw: String
  }

  /// `ls-tree --long` の1件は `<mode> <type> <object> <右寄せの size>\t<path>`。size は blob 以外
  /// では `-`。pathspec は `:(literal)` で渡しているが、念のためパスの完全一致で選ぶ。
  private func treeEntry(
    in output: String, path: String
  ) throws(GitFileHistoryError) -> TreeEntry? {
    for record in output.components(separatedBy: "\0") where !record.isEmpty {
      guard let tab = record.firstIndex(of: "\t") else { throw .unexpectedTreeEntry(record) }
      guard record[record.index(after: tab)...] == path else { continue }
      let fields = record[..<tab].split(separator: " ").map(String.init)
      guard fields.count == 4 else { throw .unexpectedTreeEntry(record) }
      return TreeEntry(
        mode: fields[0], type: fields[1], object: fields[2], size: Int(fields[3]), raw: record)
    }
    return nil
  }

  private func literalPathspec(_ path: String) throws(GitFileHistoryError) -> GitPathspec {
    // glob 文字 (`*` `?` `[`) を含むファイル名で、別のファイルまで一致させないため。
    guard !path.isEmpty, let pathspec = GitPathspec(":(literal)" + path) else {
      throw .invalidPath(path)
    }
    return pathspec
  }

  private func revision(_ value: String) throws(GitFileHistoryError) -> GitRevision {
    guard GitObjectID.isValid(value), let revision = GitRevision(value) else {
      throw .invalidCommitID(value)
    }
    return revision
  }

  private func run(
    _ command: GitReadCommand,
    timeout: Duration? = nil,
    outputLimit: Int = GitRunner.defaultOutputLimit
  ) async throws(GitFileHistoryError) -> String {
    do {
      return try await runner.run(command, timeout: timeout, outputLimit: outputLimit).stdout
    } catch {
      throw .git(error)
    }
  }
}

extension GitReadCommand {
  /// 書式を決める option はユーザーの config に左右されないよう明示する (§17.3)。
  /// `--diff-merges=first-parent` が無いと `--follow` は merge commit を一切出さない
  /// (`-m` では親ごとに同じ commit が2回出る。2.50.1 / 2.55.0 で実測)。`--follow` は diff の
  /// 結果で commit を選ぶので、`--root` が無いと `log.showRoot=false` で root commit が消える。
  static func fileHistory(pathspec: GitPathspec, maxCount: Int) -> Self {
    Self(
      arguments: historyOptions + ["--follow", "--max-count=\(maxCount)", "HEAD", "--"]
        + [pathspec.rawValue])
  }

  static func fileHistoryEntry(commit: GitRevision, pathspecs: [GitPathspec]) -> Self {
    Self(
      arguments: historyOptions + ["--no-walk", commit.rawValue, "--"] + pathspecs.map(\.rawValue))
  }

  private static let historyOptions = [
    "log", "-z", "--no-show-signature", "--encoding=UTF-8", "--find-renames",
    "--diff-merges=first-parent", "--name-status", "--root", "--format=" + GitFileHistory.format,
  ]

  /// `--no-root` は `blame.showRoot=true` で root commit の `boundary` 行が消えるのを止める
  /// (実測)。`core.quotePath=false` が無いと `filename` / `previous` の非 ASCII が8進 escape に
  /// なる。blame の path は pathspec ではない (`:(literal)` を付けるとそのままのファイル名を
  /// 探して失敗する。実測) ので素のまま渡す。
  static func blame(path: GitPathspec) -> Self {
    Self(
      arguments: [
        "-c", "core.quotePath=false", "blame", "--porcelain", "--no-root", "--encoding=UTF-8",
        "--", path.rawValue,
      ])
  }

  /// `--format=...%(path)` は使わない。`-z` と `core.quotePath=false` を付けても、`"`・制御文字・
  /// (quotePath 無しでは) 非 ASCII を含むパスを C 形式で引用する (2.50.1 / 2.55.0 で実測)。
  /// 既定の書式の `-z` は引用しない。
  static func treeEntry(commit: GitRevision, pathspec: GitPathspec) -> Self {
    Self(arguments: ["ls-tree", "-z", "--long", commit.rawValue, "--", pathspec.rawValue])
  }

  /// `show <commit>:<path>` ではなく `cat-file blob` を使う。plumbing で textconv も filter も
  /// 通らず、blob のバイト列そのものを返す。
  static func blob(_ object: GitRevision) -> Self {
    Self(arguments: ["cat-file", "blob", object.rawValue])
  }
}
