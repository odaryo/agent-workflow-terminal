import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// §8.2 の既定として、検索は明示実行 (Enter / 実行ボタン) のみ。入力ごとの自動実行と
/// debounce は入れない — 打鍵のたびに worktree 全体を走らせないため。
@MainActor
final class WorktreeSearchModel: ObservableObject {
  enum State {
    case idle
    case running
    case fullText(RipgrepSearchReport)
    case fileNames(FileNameResults)
    case failed(RipgrepRunnerError)
  }

  struct FileNameResults {
    let matches: [WorktreeFileNameMatch]
    let reachedResultLimit: Bool
    let warnings: String
    let discardedOutOfScopeCount: Int
  }

  let worktreeRoot: URL

  @Published var term = ""
  @Published var scope: WorktreeSearchScope = .respectingGitignore
  @Published var usesRegularExpression = false
  @Published var target: WorktreeSearchTarget = .fullText
  @Published private(set) var state: State = .idle
  /// 実行した時点のクエリ。入力欄をいじっても、出ている結果が何の検索かは変わらない。
  @Published private(set) var executedQuery: WorktreeSearchQuery?

  private var searchTask: Task<Void, Never>?

  init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
  }

  var isShowingResults: Bool {
    if case .idle = state { return false }
    return true
  }

  var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  func run() {
    guard
      let query = WorktreeSearchQuery(
        term: term, scope: scope, usesRegularExpression: usesRegularExpression, target: target)
    else {
      clear()
      return
    }
    // 実行中の再実行は前回を捨てる。結果が後から入れ替わらないよう、先に落としてから始める。
    searchTask?.cancel()
    executedQuery = query
    state = .running
    let root = worktreeRoot
    searchTask = Task { [weak self] in
      let outcome = await Self.execute(query: query, worktreeRoot: root)
      guard !Task.isCancelled, let self else { return }
      // 直前にキャンセルされた実行の `.cancelled` を画面へ出さない。
      if case .failure(.cancelled) = outcome { return }
      switch outcome {
      case .success(let state): self.state = state
      case .failure(let error): self.state = .failed(error)
      }
    }
  }

  func clear() {
    searchTask?.cancel()
    searchTask = nil
    executedQuery = nil
    state = .idle
  }

  /// rg の起動と待ち合わせを MainActor に載せない。
  private static func execute(
    query: WorktreeSearchQuery,
    worktreeRoot: URL
  ) async -> Result<State, RipgrepRunnerError> {
    await Task.detached(priority: .userInitiated) {
      do {
        let search = try RipgrepSearch(
          worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
        switch query.target {
        case .fullText:
          return .success(.fullText(try await search.search(query)))
        case .fileName:
          let listing = try await search.listFiles(scope: query.scope)
          let matched = WorktreeFileNameSearch.matches(term: query.term, in: listing.paths)
          let limit = WorktreeSearchLimits.maximumResultCount
          return .success(
            .fileNames(
              FileNameResults(
                matches: Array(matched.prefix(limit)),
                reachedResultLimit: matched.count > limit,
                warnings: listing.warnings,
                discardedOutOfScopeCount: listing.discardedOutOfScopeCount)))
        }
      } catch let error as RipgrepRunnerError {
        return .failure(error)
      } catch {
        return .failure(.cancelled)
      }
    }.value
  }
}
