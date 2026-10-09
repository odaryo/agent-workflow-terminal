import Adapters
import Foundation
import TerminalCore

/// `DiffViewerModel` が使う git 呼び出し (§9.1 / §9.3)。本体と分けているのは、UI 状態の遷移と
/// 外部プロセス呼び出しを別ファイルに置くためと、1ファイル・1型の行数上限 (`.swiftlint.yml`) に
/// 収めるため。
extension DiffViewerModel {
  // MARK: - git 呼び出し

  struct Context: Sendable {
    let baseBranch: DiffBaseBranch
    let refNames: GitRefNames
    let commits: [GitCommit]
  }

  /// Why not `Task.detached`: `WorktreeSearchModel` と同じ理由で、キャンセルを繋いだまま
  /// MainActor から降りるために `nonisolated` な async 関数を使う。
  nonisolated static func readContext(
    worktreeRoot: URL, userSelection: String?
  ) async -> Result<Context, DiffViewerFailure> {
    let builder: DiffSnapshotBuilder
    do {
      builder = try DiffSnapshotBuilder(
        worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
    } catch {
      return .failure(DiffViewerFailure(message: "git を利用できません: \(error)"))
    }
    do {
      return .success(
        Context(
          baseBranch: await builder.resolveBaseBranch(userSelection: userSelection),
          refNames: try await builder.refNames(),
          commits: try await builder.recentCommits(maxCount: commitListLimit)))
    } catch {
      return .failure(DiffViewerFailure(message: "Git 情報を取得できません: \(error)"))
    }
  }

  nonisolated static func readCommits(
    worktreeRoot: URL, maxCount: Int
  ) async -> Result<[GitCommit], DiffViewerFailure> {
    do {
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
      return .success(try await builder.recentCommits(maxCount: maxCount))
    } catch {
      return .failure(DiffViewerFailure(message: "commit 一覧を取得できません: \(error)"))
    }
  }

  /// 開く操作の時点の選択を写し取る (§9.1 の範囲表示)。
  func rangeContext() -> DiffSnapshotRangeContext {
    var baseSource: DiffBaseBranchSource?
    if kind == .base, case .resolved(_, let source) = baseBranch { baseSource = source }
    return DiffSnapshotRangeContext(
      worktreeName: worktreeContext().displayName,
      baseSource: baseSource,
      commit: kind == .commit ? selectedCommit.map(DiffCommitLabel.init) : nil)
  }

  nonisolated static func build(
    worktreeRoot: URL, request: DiffRequest
  ) async -> Result<DiffSnapshotBuildResult, DiffViewerFailure> {
    let builder: DiffSnapshotBuilder
    do {
      builder = try DiffSnapshotBuilder(
        worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
    } catch {
      return .failure(DiffViewerFailure(message: "git を利用できません: \(error)"))
    }
    do {
      return .success(
        try await builder.build(request, id: DiffSnapshotID(rawValue: UUID()), now: Date()))
    } catch {
      return .failure(DiffViewerFailure(message: message(for: error)))
    }
  }

  nonisolated static func observe(
    worktreeRoot: URL, request: DiffRequest
  ) async -> Result<DiffSnapshotObservation, DiffViewerFailure> {
    do {
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
      return .success(try await builder.observe(request))
    } catch {
      return .failure(DiffViewerFailure(message: "\(error)"))
    }
  }

  nonisolated static func message(for error: DiffSnapshotBuilderError) -> String {
    switch error {
    case .unsupportedMergeCommit(let parents):
      // どの親と比べるかは設計書が定めていない (§9.1.2)。第一親を推測で選ばない。
      "merge commit の Diff は未対応です (親 \(parents.count) 件)"
    case .noMergeBase(let branch):
      // 空 tree や root commit を起点に代えない (§9.1.2)。
      "\(branch) と HEAD に共通祖先 (merge-base) が無いため、merge-base 起点の Diff を作れません"
    case .mergeBaseUnresolved(let branch, let reason):
      // 「共通祖先が無い」と断定しない (§9.1.4)。
      "\(branch) と HEAD の merge-base を求められませんでした (共通祖先が無いとは限りません): "
        + reason.explanation
    case .invalidRevision(let value):
      "revision を解決できません: \(value)"
    case .git(let error):
      "git の実行に失敗しました: \(error)"
    }
  }

  nonisolated static func notices(for result: DiffSnapshotBuildResult) -> [String] {
    var notices: [String] = []
    if !result.patchFailures.isEmpty {
      notices.append("Diff の一部を解析できていません (\(result.patchFailures.count) 件)")
    }
    if !result.statusFailures.isEmpty {
      notices.append("status の一部を解析できていません (\(result.statusFailures.count) 件)")
    }
    if !result.unreadableUntrackedPaths.isEmpty {
      notices.append(
        "untracked の内容を読めていません (\(result.unreadableUntrackedPaths.count) 件)")
    }
    return notices
  }
}

extension DiffMergeBaseUnresolvedReason {
  fileprivate var explanation: String {
    switch self {
    case .shallowRepository: "shallow clone のため、取得済みの履歴より古い共通祖先は辿れません"
    case .rewrittenHistory: "replace / grafts が親子関係を書き換えています"
    case .gitReported(let stderr):
      "git の警告: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    case .historyCheckFailed(let detail): "履歴の状態を確かめられませんでした: \(detail)"
    }
  }
}
