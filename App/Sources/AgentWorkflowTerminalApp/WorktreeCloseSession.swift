import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// Close を開いた時点の Project 側の値と、実行の前後に `AppModel` へ問い合わせる経路。
struct WorktreeCloseContext {
  /// git の書き込みを撃つディレクトリ。**消す worktree の中を指してはならない**
  /// (`WorktreeCloseExecutor` の doc コメント) ので、Project Root の作業ツリーを渡す。
  let repositoryDirectory: URL
  let projectRootBranch: String?
  /// 実行の直前に、いまの一覧からもう一度引く。消えていれば `nil`。
  let currentTarget: @MainActor () -> DetectedWorktree?
  let didClose: @MainActor (WorktreeIdentity) -> Void
}

/// Project ごとに1つ。開いている Close の確認は同時に1つだけにする。
@MainActor
final class WorktreeClosing: ObservableObject {
  @Published private(set) var session: WorktreeCloseSession?

  private let tmuxRunner: TmuxRunner?
  private let processRunner: any ProcessRunning
  /// Close を開き直すたびに squash 走査を払わないため、確認をまたいで持つ (Issue #366)。
  private let mergeCache = GitBranchMergeCache()

  init(tmuxRunner: TmuxRunner?, processRunner: any ProcessRunning = FoundationProcessRunner()) {
    self.tmuxRunner = tmuxRunner
    self.processRunner = processRunner
  }

  func open(target: DetectedWorktree, context: WorktreeCloseContext) {
    session?.cancelInspection()
    let session = WorktreeCloseSession(
      target: target, context: context, tmuxRunner: tmuxRunner, processRunner: processRunner,
      mergeCache: mergeCache)
    session.dismiss = { [weak self, weak session] in
      guard let self, let session, self.session === session else { return }
      self.dismiss()
    }
    self.session = session
    session.inspect()
  }

  func dismiss() {
    session?.cancelInspection()
    session = nil
  }
}

/// 1回の Close の確認。検査 → 選択と確認 → 実行 → 結果、の順に進む (設計書 §3.4)。
@MainActor
final class WorktreeCloseSession: ObservableObject {
  enum Phase: Sendable {
    case inspecting
    /// 検査器を組み立てられなかった (git が無いなど)。
    case inspectionUnavailable(String)
    case ready(WorktreeCloseReview)
    case executing(WorktreeCloseReview)
    case finished(WorktreeCloseResultText)
  }

  @Published private(set) var phase = Phase.inspecting
  @Published var option = WorktreeCloseOption.hideFromUI {
    didSet { acknowledged = false }
  }
  /// 警告を見たうえで続行を選んだか。選択肢を変えたら外す —— 別の選択肢の警告を見た確認を
  /// 持ち越さない。
  @Published var acknowledged = false

  let target: DetectedWorktree
  fileprivate var dismiss: @MainActor () -> Void = {}

  private let context: WorktreeCloseContext
  private let tmuxRunner: TmuxRunner?
  private let processRunner: any ProcessRunning
  private let mergeCache: GitBranchMergeCache
  private var inspection: Task<Void, Never>?

  init(
    target: DetectedWorktree, context: WorktreeCloseContext, tmuxRunner: TmuxRunner?,
    processRunner: any ProcessRunning, mergeCache: GitBranchMergeCache
  ) {
    self.target = target
    self.context = context
    self.tmuxRunner = tmuxRunner
    self.processRunner = processRunner
    self.mergeCache = mergeCache
  }

  /// 検査は毎回やり直す。**未commit変更の確認を使い回さない** (`WorktreeRemovalConfirmation` の
  /// doc コメント) ため、再利用するのは commit の OID で鍵を引ける merge 判定だけである。
  func inspect() {
    inspection?.cancel()
    phase = .inspecting
    acknowledged = false
    let target = target
    let projectRootBranch = context.projectRootBranch
    let canTerminateSessions = tmuxRunner != nil
    let processRunner = processRunner
    let mergeCache = mergeCache
    inspection = Task {
      let phase = await Self.runInspection(
        target: target, projectRootBranch: projectRootBranch,
        canTerminateSessions: canTerminateSessions, processRunner: processRunner,
        mergeCache: mergeCache)
      // 取り消した検査の答えは、取り消しで失敗した git の結果を含むので表示しない。
      guard !Task.isCancelled else { return }
      self.phase = phase
    }
  }

  func cancelInspection() {
    inspection?.cancel()
    inspection = nil
  }

  func close() {
    dismiss()
  }

  func execute() {
    guard case .ready(let review) = phase, review.refusal == nil,
      review.unavailability(of: option) == nil,
      !review.requiresAcknowledgement(option) || acknowledged
    else { return }
    // 検査の後に移動・切り替えられた worktree へ、検査した値のまま撃たない。
    guard let current = context.currentTarget(), current.isReachable,
      current.worktreePath.utf8.elementsEqual(target.worktreePath.utf8),
      current.branch?.utf8.elementsEqual((target.branch ?? "").utf8) == true
    else {
      phase = .finished(
        .init(
          closedWorktree: false, headline: "検査の後に worktree の状態が変わったため、何も実行しませんでした。",
          details: ["再検査してから、もう一度選んでください。"]))
      return
    }
    let plan: WorktreeClosePlan
    do {
      plan = try review.plan(option, acknowledged: acknowledged)
    } catch {
      let refusal = WorktreeCloseRefusalText(error, progressFailure: review.progress.failure)
      phase = .finished(
        .init(closedWorktree: false, headline: refusal.reason, details: [refusal.guidance]))
      return
    }
    phase = .executing(review)
    let target = target
    let tmuxRunner = tmuxRunner
    let processRunner = processRunner
    let repositoryDirectory = context.repositoryDirectory
    // 取り消しを用意しない。session 終了・worktree 削除は巻き戻せず、途中で止めても
    // 「何もしなかった」状態へは戻らない (§3.4)。
    Task {
      let result = await Self.runExecution(
        plan, target: target, tmuxRunner: tmuxRunner, processRunner: processRunner,
        repositoryDirectory: repositoryDirectory)
      if result.closedWorktree {
        context.didClose(target.identity)
      }
      if result.closedWorktree, result.details.isEmpty {
        dismiss()
      } else {
        phase = .finished(result)
      }
    }
  }

  nonisolated private static func runInspection(
    target: DetectedWorktree, projectRootBranch: String?, canTerminateSessions: Bool,
    processRunner: any ProcessRunning, mergeCache: GitBranchMergeCache
  ) async -> Phase {
    let progressInspector: GitWorktreeProgressInspector
    let safetyInspector: GitCloseSafetyInspector
    do {
      progressInspector = try GitWorktreeProgressInspector(
        target: target, processRunner: processRunner)
      safetyInspector = try GitCloseSafetyInspector(
        target: target, processRunner: processRunner, mergeCache: mergeCache)
    } catch {
      return .inspectionUnavailable("検査を始められませんでした: \(error.closeDescription)")
    }
    async let progress = progressInspector.inspect()
    async let safety = safetyInspector.inspect(projectRootBranch: projectRootBranch)
    return .ready(
      WorktreeCloseReview(
        target: target, progress: await progress, safety: await safety,
        canTerminateSessions: canTerminateSessions))
  }

  nonisolated private static func runExecution(
    _ plan: WorktreeClosePlan, target: DetectedWorktree, tmuxRunner: TmuxRunner?,
    processRunner: any ProcessRunning, repositoryDirectory: URL
  ) async -> WorktreeCloseResultText {
    // 選択肢1は外部プロセスへ撃つものが無い (`planWorktreeClose` の doc コメント)。tmux を
    // 使えない起動でも Inactive にできるよう、実行層を組み立てずに済ませる。
    guard !plan.steps.isEmpty else { return .succeeded }
    guard let tmuxRunner else {
      return .init(
        closedWorktree: false, headline: "tmux を利用できないため、何も実行しませんでした。", details: [])
    }
    let executor: WorktreeCloseExecutor
    do {
      executor = try WorktreeCloseExecutor(
        repositoryDirectory: repositoryDirectory, worktree: target,
        sessionOperations: TmuxSessionOperations(runner: tmuxRunner),
        processRunner: processRunner)
    } catch {
      return .init(
        closedWorktree: false, headline: "Close を始められず、何も実行しませんでした。",
        details: [error.closeDescription])
    }
    do {
      return WorktreeCloseResultText(try await executor.execute(plan))
    } catch {
      return .init(
        closedWorktree: false, headline: "計画と対象が一致しないため、何も実行しませんでした。",
        details: ["\(error)"])
    }
  }
}

/// 実行の結果。`details` が空なのは全 step が成功したときだけ。
struct WorktreeCloseResultText: Sendable {
  /// この worktree を Inactive にしてタブから外すか。全 step の成功に加え、worktree の削除まで
  /// 済んだ場合も外す —— 作業ツリーが無いタブを Active のまま残すと、再 attach が
  /// `new-session -c <無いディレクトリ>` で `$HOME` へ黙って落ちる (`AppModel.select(_:)` の
  /// doc コメント)。
  let closedWorktree: Bool
  let headline: String
  let details: [String]

  static let succeeded = Self(closedWorktree: true, headline: "Close しました。", details: [])

  init(closedWorktree: Bool, headline: String, details: [String]) {
    self.closedWorktree = closedWorktree
    self.headline = headline
    self.details = details
  }

  init(_ execution: WorktreeCloseExecution) {
    switch execution {
    case .abandoned(let refusal):
      self.init(
        closedWorktree: false,
        headline: "計画の後に状態が変わったため、何も実行しませんでした。",
        details: [refusal.closeDescription])
    case .executed(let outcome):
      guard let failure = outcome.failure else {
        self = .succeeded
        return
      }
      let removed = outcome.completed.contains {
        if case .removeWorktree = $0 { return true }
        return false
      }
      self.init(
        closedWorktree: removed,
        headline: "Close は「\(failure.step.closeDescription)」で止まりました。",
        details: outcome.completed.map { "完了: \($0.closeDescription)" }
          + ["失敗: \(failure.step.closeDescription) — \(failure.reason.closeDescription)"]
          + outcome.skipped.map { "未実行: \($0.closeDescription)" })
    }
  }
}
