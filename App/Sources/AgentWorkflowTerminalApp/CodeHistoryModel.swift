import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// Code ペインの表示切り替え (§7.3)。本文は `FileBrowserModel` が持ち、ここは履歴と blame だけを
/// 持つ。過去版を `FileBrowserModel.content` に入れないのは、ファイル変更の監視が現在の版を
/// 読み直して過去版の表示を上書きするのを避けるため。
enum CodeViewerMode: Hashable {
  case current
  case history
  case blame
}

enum CodeHistoryLoad<Value> {
  case idle
  case loading
  case loaded(Value)
  /// git の stderr をそのまま見せる (§7.3)。
  case failed(String)

  var value: Value? {
    if case .loaded(let value) = self { value } else { nil }
  }

  var failedAsDiff: CodeHistoryLoad<GitFileHistoryDiff> {
    if case .failed(let message) = self { .failed(message) } else { .idle }
  }
}

enum CodeHistoryOutcome<Value> {
  case success(Value)
  case failure(String)
}

struct CodeHistoryList {
  let records: [GitFileHistoryRecord]
  let hasMore: Bool
  let limit: Int
}

struct CodePastVersion {
  let version: GitFileVersion
  var highlight: FileContentLoad.HighlightOutcome?
}

/// blame の1行。注記はその commit が連続する行の先頭にだけ付ける。
struct CodeBlameRow: Identifiable {
  struct Annotation {
    let commit: GitBlameCommit
    /// 行から履歴項目へ移るときに `--no-walk` へ渡すパス (その commit 時点と rename 元)。
    let paths: [String]
  }

  let id: Int
  let content: String
  let annotation: Annotation?
  /// 連続する同じ commit の行の塊の通し番号。塊の境目を見た目で分けるのに使う。
  let runIndex: Int
}

@MainActor
final class CodeHistoryModel: ObservableObject {
  enum PastView: Hashable {
    case code
    case diff
  }

  @Published var mode: CodeViewerMode = .current
  @Published private(set) var history: CodeHistoryLoad<CodeHistoryList> = .idle
  @Published private(set) var selectedEntry: GitFileHistoryEntry?
  @Published var pastView: PastView = .code
  @Published private(set) var pastVersion: CodeHistoryLoad<CodePastVersion> = .idle
  @Published private(set) var pastDiff: CodeHistoryLoad<GitFileHistoryDiff> = .idle
  @Published private(set) var blame: CodeHistoryLoad<[CodeBlameRow]> = .idle
  /// 履歴の Diff を既存の表示で出すための、選択もコメントも持たない Diff Viewer の model。
  let idleDiffModel: DiffViewerModel
  var prefersDarkTheme = false

  private let worktreeRoot: URL
  private var path: String?
  private var historyTask: Task<Void, Never>?
  private var versionTask: Task<Void, Never>?
  private var diffTask: Task<Void, Never>?
  private var entryTask: Task<Void, Never>?
  private var blameTask: Task<Void, Never>?
  private var pastConfirmation: FileOpenConfirmation = .notConfirmed

  init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
    idleDiffModel = DiffViewerModel(worktreeRoot: worktreeRoot)
  }

  /// `relativePath` は worktree root からの相対パス。ファイルを選び直すたびに本文表示へ戻す。
  func reset(relativePath: String?) {
    historyTask?.cancel()
    blameTask?.cancel()
    path = relativePath
    mode = .current
    history = .idle
    blame = .idle
    clearSelectedEntry()
  }

  /// Task は model が解放されても自動では取り消されず、git の子プロセスは timeout まで走り続ける。
  /// 状態は戻さない: 再表示されたときは `.task(id: model.selection)` が `reset` から読み直す。
  func cancelAll() {
    for task in [historyTask, versionTask, diffTask, entryTask, blameTask] { task?.cancel() }
  }

  func showCurrent() {
    blameTask?.cancel()
    mode = .current
    clearSelectedEntry()
  }

  func showHistory() {
    mode = .history
    if case .idle = history { loadHistory(limit: GitFileHistoryReader.pageSize) }
  }

  /// `--skip` では rename を越えられないので、上限を広げて最初から読み直す
  /// (`GitFileHistoryReader.history`)。
  func loadMoreHistory() {
    let limit = (history.value?.limit ?? 0) + GitFileHistoryReader.pageSize
    loadHistory(limit: limit)
  }

  func reloadHistory() {
    loadHistory(limit: history.value?.limit ?? GitFileHistoryReader.pageSize)
  }

  /// `isExpandable` は現在の版が §7.2 で本文を展開するか。展開しないファイルは blame も出さない。
  func showBlame(isExpandable: Bool) {
    mode = .blame
    guard isExpandable else {
      blameTask?.cancel()
      blame = .idle
      return
    }
    loadBlame()
  }

  func cancelBlame() {
    blameTask?.cancel()
    blame = .failed("blame を取り消しました。")
  }

  func reloadBlame() {
    loadBlame()
  }

  /// commit / checkout で HEAD から辿る履歴と blame の帰属が変わる。表示していない履歴は
  /// 捨てておき、次に開いたときに読み直す。
  func gitIndexDidChange(isExpandable: Bool) {
    if mode == .history {
      reloadHistory()
    } else {
      historyTask?.cancel()
      history = .idle
    }
    if mode == .blame { showBlame(isExpandable: isExpandable) }
  }

  /// working tree の変更で blame の未 commit 行が変わる。
  func fileDidChange(isExpandable: Bool) {
    guard mode == .blame else { return }
    showBlame(isExpandable: isExpandable)
  }

  func select(_ entry: GitFileHistoryEntry) {
    guard entry != selectedEntry else { return }
    cancelPastLoads()
    selectedEntry = entry
    pastConfirmation = .notConfirmed
    pastVersion = .idle
    pastDiff = .idle
    loadPast()
  }

  func showPastView(_ view: PastView) {
    pastView = view
    loadPast()
  }

  func confirmOpenPastVersion() {
    pastConfirmation = .confirmed
    pastVersion = .idle
    loadPast()
  }

  func appearanceDidChange(isDark: Bool) {
    prefersDarkTheme = isDark
    guard case .loaded = pastVersion else { return }
    pastVersion = .idle
    loadPast()
  }

  /// blame の注記から、その commit の履歴項目へ移る。
  func showHistoryEntry(for annotation: CodeBlameRow.Annotation) {
    mode = .history
    if case .idle = history { loadHistory(limit: GitFileHistoryReader.pageSize) }
    let commitID = annotation.commit.commitID
    if let entry = history.value?.records.lazy.compactMap(\.entryValue).first(where: {
      $0.commitID == commitID
    }) {
      select(entry)
      return
    }
    cancelPastLoads()
    selectedEntry = nil
    pastVersion = .loading
    pastDiff = .idle
    let root = worktreeRoot
    entryTask = Task {
      let outcome = await Self.perform(root) {
        try await $0.entry(commitID: commitID, paths: annotation.paths)
      }
      guard !Task.isCancelled else { return }
      switch outcome {
      case .success(let entry?):
        pastVersion = .idle
        select(entry)
      case .success(nil):
        pastVersion = .failed("commit \(commitID) はこのファイルの履歴にありません。")
      case .failure(let message):
        pastVersion = .failed(message)
      }
    }
  }

  // MARK: -

  private func cancelPastLoads() {
    entryTask?.cancel()
    versionTask?.cancel()
    diffTask?.cancel()
  }

  private func clearSelectedEntry() {
    cancelPastLoads()
    selectedEntry = nil
    pastConfirmation = .notConfirmed
    pastView = .code
    pastVersion = .idle
    pastDiff = .idle
  }

  private func loadHistory(limit: Int) {
    guard let path else { return }
    historyTask?.cancel()
    history = .loading
    let root = worktreeRoot
    historyTask = Task {
      let outcome = await Self.perform(root) { try await $0.history(path: path, limit: limit) }
      guard !Task.isCancelled else { return }
      switch outcome {
      case .success(let page):
        history = .loaded(
          CodeHistoryList(records: page.records, hasMore: page.hasMore, limit: limit))
      case .failure(let message):
        history = .failed(message)
      }
    }
  }

  private func loadBlame() {
    guard let path else { return }
    blameTask?.cancel()
    blame = .loading
    let root = worktreeRoot
    blameTask = Task {
      let outcome = await Self.perform(root) { reader in
        Self.rows(of: try await reader.blame(path: path))
      }
      guard !Task.isCancelled else { return }
      switch outcome {
      case .success(let rows): blame = .loaded(rows)
      case .failure(let message): blame = .failed(message)
      }
    }
  }

  private func loadPast() {
    guard let entry = selectedEntry else { return }
    guard let change = entry.changes.first else {
      pastVersion = .failed("この commit にはこのファイルの変更が記録されていません。")
      pastDiff = pastVersion.failedAsDiff
      return
    }
    switch pastView {
    case .code: loadPastVersion(entry: entry, change: change)
    case .diff: loadPastDiff(entry: entry, change: change)
    }
  }

  private func loadPastVersion(entry: GitFileHistoryEntry, change: GitFileHistoryChange) {
    guard case .idle = pastVersion else { return }
    pastVersion = .loading
    let root = worktreeRoot
    let confirmation = pastConfirmation
    let isDark = prefersDarkTheme
    versionTask = Task {
      let outcome = await Self.perform(root) {
        try await $0.version(
          commitID: entry.commitID, path: change.path, confirmation: confirmation)
      }
      guard !Task.isCancelled, entry == selectedEntry else { return }
      switch outcome {
      case .success(let version):
        let highlight = await Self.highlight(version, path: change.path, isDark: isDark)
        guard !Task.isCancelled, entry == selectedEntry else { return }
        pastVersion = .loaded(CodePastVersion(version: version, highlight: highlight))
      case .failure(let message):
        pastVersion = .failed(message)
      }
    }
  }

  private func loadPastDiff(entry: GitFileHistoryEntry, change: GitFileHistoryChange) {
    guard case .idle = pastDiff else { return }
    pastDiff = .loading
    let root = worktreeRoot
    diffTask = Task {
      let outcome = await Self.perform(root) {
        try await $0.diff(commitID: entry.commitID, parentIDs: entry.parentIDs, change: change)
      }
      guard !Task.isCancelled, entry == selectedEntry else { return }
      switch outcome {
      case .success(let diff): pastDiff = .loaded(diff)
      case .failure(let message): pastDiff = .failed(message)
      }
    }
  }

  /// git の起動と出力の解析は `GitFileHistoryReader` の nonisolated な async 関数の中で
  /// 走るので MainActor に載らない。Task の取り消しは子プロセスの停止まで伝わる。
  private static func perform<Value: Sendable>(
    _ root: URL,
    _ body: @Sendable (GitFileHistoryReader) async throws -> Value
  ) async -> CodeHistoryOutcome<Value> {
    do {
      let reader = try GitFileHistoryReader(
        worktreeRoot: root, processRunner: FoundationProcessRunner())
      return .success(try await body(reader))
    } catch let error as GitFileHistoryError {
      return .failure(message(for: error))
    } catch let error as GitRunnerError {
      return .failure(message(for: .git(error)))
    } catch {
      return .failure(String(describing: error))
    }
  }

  private static func highlight(
    _ version: GitFileVersion, path: String, isDark: Bool
  ) async -> FileContentLoad.HighlightOutcome? {
    guard case .content(let result) = version, let text = result.text else { return nil }
    let name = path.split(separator: "/").last.map(String.init) ?? path
    guard let language = SyntaxHighlightLanguage.name(forFileName: name) else {
      return .unsupportedFileType
    }
    let byteCount = text.content.utf8.count
    guard byteCount <= SyntaxHighlightingService.maximumByteCount else {
      return .tooLarge(byteCount: byteCount, maximum: SyntaxHighlightingService.maximumByteCount)
    }
    guard
      let highlighted = await SyntaxHighlightingService.shared.highlight(
        text.content, language: language, isDark: isDark)
    else { return .unavailable }
    return .highlighted(highlighted.text, background: highlighted.background)
  }

  nonisolated static func rows(of result: GitBlameParseResult) -> [CodeBlameRow] {
    let lines = result.lines
    var rows: [CodeBlameRow] = []
    rows.reserveCapacity(lines.count)
    for (runIndex, run) in BlameAnnotationRuns.runs(of: lines.map(\.commitID)).enumerated() {
      for index in run {
        let line = lines[index]
        var annotation: CodeBlameRow.Annotation?
        if index == run.lowerBound, let commit = result.commit(for: line) {
          let paths = [line.path, commit.previous?.path].compactMap { $0 }
          annotation = .init(commit: commit, paths: paths)
        }
        rows.append(
          CodeBlameRow(
            id: line.finalLineNumber, content: line.content, annotation: annotation,
            runIndex: runIndex))
      }
    }
    return rows
  }

  nonisolated static func message(for error: GitFileHistoryError) -> String {
    switch error {
    case .git(.commandFailed(let exitCode, _, let stderr)):
      stderr.isEmpty ? "git が失敗しました (exit \(exitCode))" : stderr
    case .git(.process(.timedOut(_, _, let stderr))):
      "git が時間内に終わりませんでした。" + (stderr.isEmpty ? "" : "\n" + stderr)
    case .git(.process(.outputLimitExceeded(let limit))):
      "git の出力が上限 (\(limit) バイト) を超えました。"
    case .git(.process(.cancelled)):
      "取り消しました。"
    case .git(let error):
      "git を実行できません: \(error)"
    case .invalidPath(let path):
      "git へ渡せないパスです: \(path)"
    case .invalidCommitID(let id):
      "commit ID として扱えません: \(id)"
    case .unexpectedTreeEntry(let entry):
      "git ls-tree の出力を解釈できません: \(entry)"
    }
  }
}

extension GitFileHistoryRecord {
  var entryValue: GitFileHistoryEntry? {
    if case .entry(let entry) = self { entry } else { nil }
  }
}
