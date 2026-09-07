import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// File Browser の1行。`path` は Git 状態を引くためのキーで、表示には使わない
/// (`WorktreeRelativePath` は NFC 正規化して保持するため、ファイルシステム上の名前と食い違う)。
struct FileBrowserRow: Identifiable {
  enum Content {
    case entry(kind: FileBrowserChildKind, path: WorktreeRelativePath?, url: URL)
    /// 空のディレクトリと読めないディレクトリを同じ「0 件」に丸めないための行 (§12.3)。
    case note(String)
  }

  let id: String
  let name: String
  let depth: Int
  let content: Content
}

struct FileBrowserSelection: Equatable {
  let id: String
  let name: String
  let url: URL
  let path: WorktreeRelativePath?
}

struct FileContentLoad {
  enum HighlightOutcome {
    case highlighted(AttributedString, background: Color)
    case unsupportedFileType
    case tooLarge(byteCount: Int, maximum: Int)
    case unavailable
  }

  let result: FileContentReadResult
  var highlight: HighlightOutcome?
}

/// `git status` から得た重ね合わせと、そこで落ちた分。落ちた分を黙って捨てると、そのパスは
/// 既定規則で「tracked・変更なし」に化けて、観測していない状態を主張することになる (§12.3)。
struct WorktreeGitStateSnapshot {
  let overlay: WorktreeFileGitStateOverlay
  let incompleteEntryCount: Int
  let submoduleListingFailed: Bool
}

@MainActor
final class FileBrowserModel: ObservableObject {
  enum DirectoryListing {
    case children([FileBrowserChild])
    case failure(FileBrowserDirectoryReaderError)
  }

  let worktreeRoot: URL

  @Published private(set) var listings: [String: DirectoryListing] = [:]
  @Published private(set) var expanded: Set<String> = []
  @Published private(set) var gitState: WorktreeGitStateSnapshot?
  @Published private(set) var gitStateError: GitRunnerError?
  @Published var selection: FileBrowserSelection?
  /// テーマは highlight 時にしか選べないので、外観の変更は本文の読み直しで反映する。
  @Published var prefersDarkTheme = false
  @Published private(set) var content: FileContentLoad?
  @Published private(set) var contentError: FileContentReaderError?
  @Published private(set) var isSelectionDeleted = false

  private let reader: FileBrowserDirectoryReader
  private var confirmation: FileOpenConfirmation = .notConfirmed
  private var isRefreshingGitState = false

  init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
    reader = FileBrowserDirectoryReader(worktreeRoot: worktreeRoot)
  }

  // MARK: - ツリー

  var rows: [FileBrowserRow] {
    var rows: [FileBrowserRow] = []
    appendRows(directoryID: "", directoryURL: worktreeRoot, depth: 0, into: &rows)
    return rows
  }

  func isExpanded(_ row: FileBrowserRow) -> Bool { expanded.contains(row.id) }

  func toggleExpansion(of row: FileBrowserRow) {
    guard case .entry(.directory, let path, _) = row.content, let path else { return }
    if expanded.contains(row.id) {
      expanded.remove(row.id)
      return
    }
    expanded.insert(row.id)
    loadDirectory(id: row.id, path: path)
  }

  func loadRoot() {
    loadDirectory(id: "", path: nil)
  }

  private func loadDirectory(id: String, path: WorktreeRelativePath?) {
    do {
      listings[id] = .children(try reader.children(in: path))
    } catch let error as FileBrowserDirectoryReaderError {
      listings[id] = .failure(error)
    } catch {
      listings[id] = .failure(.listingFailed(path?.value ?? worktreeRoot.path))
    }
    // 再列挙は Git 状態の更新契機のひとつ (ラウンド3 spec 要求1)。
    refreshGitState()
  }

  private func appendRows(
    directoryID: String,
    directoryURL: URL,
    depth: Int,
    into rows: inout [FileBrowserRow]
  ) {
    switch listings[directoryID] {
    case nil:
      return
    case .failure(let error):
      rows.append(
        FileBrowserRow(
          id: directoryID + "\u{0000}note",
          name: message(for: error),
          depth: depth,
          content: .note(message(for: error))))
    case .children(let children) where children.isEmpty:
      rows.append(
        FileBrowserRow(
          id: directoryID + "\u{0000}note",
          name: "(空のディレクトリ)",
          depth: depth,
          content: .note("(空のディレクトリ)")))
    case .children(let children):
      for child in children {
        let id = directoryID.isEmpty ? child.name : directoryID + "/" + child.name
        let row = FileBrowserRow(
          id: id,
          name: child.name,
          depth: depth,
          content: .entry(
            kind: child.kind,
            path: WorktreeRelativePath(id),
            url: directoryURL.appending(path: child.name)))
        rows.append(row)
        guard child.kind == .directory, expanded.contains(id) else { continue }
        appendRows(
          directoryID: id,
          directoryURL: directoryURL.appending(path: child.name),
          depth: depth + 1,
          into: &rows)
      }
    }
  }

  private func message(for error: FileBrowserDirectoryReaderError) -> String {
    switch error {
    case .unreadable: "(読み取り権限がありません)"
    case .notDirectory: "(ディレクトリではありません)"
    case .symbolicLink: "(シンボリックリンクは辿りません)"
    case .listingFailed: "(一覧を取得できません)"
    }
  }

  // MARK: - Git 状態

  func gitState(for row: FileBrowserRow) -> WorktreeFileGitState? {
    guard case .entry(let kind, let path, _) = row.content, let path, let gitState else {
      return nil
    }
    return gitState.overlay.state(
      for: path, kind: kind == .directory ? .directory : .file)
  }

  /// 監視できるのは `.git/index` の mtime、タブの活性化、再列挙の3つだけ。作業ツリーの
  /// ファイルを直接書き換える変更 (agent の編集) は index を触らないので badge は古いままになる。
  /// 検知できないぶんは「更新」ボタンで明示的に取り直す — 黙って最新の顔をさせない (§12.3)。
  func refreshGitState() {
    guard !isRefreshingGitState else { return }
    isRefreshingGitState = true
    let root = worktreeRoot
    Task {
      let outcome = await Self.readGitState(worktreeRoot: root)
      switch outcome {
      case .success(let result):
        gitState = WorktreeGitStateSnapshot(
          overlay: WorktreeFileGitStateOverlay(entries: result.entries),
          incompleteEntryCount: result.statusParseFailures.count + result.conversionFailures.count,
          submoduleListingFailed: result.submoduleListingFailure != nil)
        gitStateError = nil
      case .failure(let error):
        gitStateError = error
      }
      isRefreshingGitState = false
    }
  }

  /// `git` の起動と待ち合わせを MainActor に載せない。
  private static func readGitState(
    worktreeRoot: URL
  ) async -> Result<WorktreeGitStateReadResult, GitRunnerError> {
    await Task.detached(priority: .userInitiated) {
      do {
        let reader = try WorktreeGitStateReader(
          repositoryDirectory: worktreeRoot,
          processRunner: FoundationProcessRunner())
        return .success(try await reader.read())
      } catch let error as GitRunnerError {
        return .failure(error)
      } catch {
        return .failure(.invalidRepositoryDirectory(worktreeRoot))
      }
    }.value
  }

  /// worktree では `.git` はディレクトリではなくファイルで、index は `gitdir:` が指す先にある。
  var gitIndexURL: URL? {
    let dotGit = worktreeRoot.appending(path: ".git")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
      return nil
    }
    if isDirectory.boolValue { return dotGit.appending(path: "index") }
    guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
      let line = contents.split(separator: "\n").first,
      line.hasPrefix("gitdir: ")
    else { return nil }
    let path = String(line.dropFirst("gitdir: ".count))
    let gitDirectory =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path) : worktreeRoot.appending(path: path).standardizedFileURL
    return gitDirectory.appending(path: "index")
  }

  // MARK: - 本文

  func select(_ row: FileBrowserRow) {
    guard case .entry(.file, let path, let url) = row.content else { return }
    selection = FileBrowserSelection(id: row.id, name: row.name, url: url, path: path)
  }

  func confirmOpen() async {
    confirmation = .confirmed
    await loadContent()
  }

  func loadContent() async {
    guard let selection else {
      content = nil
      contentError = nil
      return
    }
    isSelectionDeleted = false
    let outcome = await Self.read(url: selection.url, confirmation: confirmation)
    guard selection == self.selection else { return }
    switch outcome {
    case .success(let result):
      content = FileContentLoad(result: result, highlight: nil)
      contentError = nil
      await highlight(name: selection.name, result: result, for: selection)
    case .failure(let error):
      content = nil
      contentError = error
    }
  }

  func resetSelectionState() {
    confirmation = .notConfirmed
    content = nil
    contentError = nil
    isSelectionDeleted = false
  }

  func markSelectionDeleted() {
    isSelectionDeleted = true
  }

  /// `FileContentReader.read` は同期で、16 MiB では 7.6 ms かかる (ラウンド3 spec の計測)。
  private static func read(
    url: URL,
    confirmation: FileOpenConfirmation
  ) async -> Result<FileContentReadResult, FileContentReaderError> {
    await Task.detached(priority: .userInitiated) {
      do {
        return .success(try FileContentReader().read(url: url, confirmation: confirmation))
      } catch let error as FileContentReaderError {
        return .failure(error)
      } catch {
        return .failure(.readFailed(url.path))
      }
    }.value
  }

  private func highlight(
    name: String,
    result: FileContentReadResult,
    for selection: FileBrowserSelection
  ) async {
    // 本文が無い場合 (確認待ち・バイナリ) に「ハイライトできなかった」と出すと、
    // 表示されない理由が2つあるように読める。
    guard let text = result.text else { return }
    guard let language = SyntaxHighlightLanguage.name(forFileName: name) else {
      content?.highlight = .unsupportedFileType
      return
    }
    let byteCount = text.content.utf8.count
    guard byteCount <= SyntaxHighlightingService.maximumByteCount else {
      content?.highlight = .tooLarge(
        byteCount: byteCount, maximum: SyntaxHighlightingService.maximumByteCount)
      return
    }
    let highlighted = await SyntaxHighlightingService.shared.highlight(
      text.content, language: language, isDark: prefersDarkTheme)
    guard selection == self.selection else { return }
    guard let highlighted else {
      content?.highlight = .unavailable
      return
    }
    content?.highlight = .highlighted(highlighted.text, background: highlighted.background)
  }
}
