import Adapters
import TerminalCore

/// 設計書 §3.4 の選択肢1〜4。
enum WorktreeCloseOption: CaseIterable, Hashable, Sendable {
  case hideFromUI
  case terminateSession
  case removeWorktree
  case deleteBranch

  var choice: WorktreeCloseChoice {
    switch self {
    case .hideFromUI: .hideFromUI
    case .terminateSession: .terminateSession(.keepWorktree)
    case .removeWorktree: .terminateSession(.removeWorktree(.keepBranch))
    case .deleteBranch: .terminateSession(.removeWorktree(.deleteBranch))
    }
  }

  var removesWorktree: Bool {
    switch self {
    case .hideFromUI, .terminateSession: false
    case .removeWorktree, .deleteBranch: true
    }
  }

  var terminatesSession: Bool { self != .hideFromUI }
}

/// 検査結果を、Close の確認に出す拒否・選択肢の可否・警告へ写す。
///
/// - Important: 可否は自前の条件で書かず、`planWorktreeClose` に問う。UI の条件と計画層の条件が
///   別々にあると、画面で選べたのに計画が拒否する (またはその逆) の食い違いが生まれる。理由の
///   **文言**だけを検査結果から組み立てる。
struct WorktreeCloseReview: Sendable {
  let target: DetectedWorktree
  let progress: GitWorktreeProgressInspectionResult
  let safety: GitCloseSafetyInspectionResult
  /// `false` なら session を終了する手段が無く、選択肢2〜4を出さない。
  let canTerminateSessions: Bool

  /// 選択肢1〜4のすべてを拒否する理由 (§3.4 の detached HEAD・作業途中)。`nil` なら拒否しない。
  var refusal: WorktreeClosePlanError? {
    do {
      _ = try planWorktreeClose(
        worktree: target, progress: progress.report, choice: .hideFromUI, confirmation: nil)
      return nil
    } catch {
      return error
    }
  }

  /// その選択肢を選べない理由。`nil` なら選べる。
  func unavailability(of option: WorktreeCloseOption) -> String? {
    if option.terminatesSession, !canTerminateSessions {
      return "tmux を利用できないため、session を終了できません。"
    }
    guard option == .deleteBranch else { return nil }
    do {
      _ = try plan(.deleteBranch, acknowledged: true)
      return nil
    } catch {
      return branchDeletionUnavailability
    }
  }

  /// 選択肢3・4で削除の前に知らせる事項 (§3.4 の表)。
  var removalWarnings: [String] {
    let inspection = safety.report.inspection
    var warnings: [String] = []
    switch inspection.uncommittedChanges {
    case .present: warnings.append("未commit の変更または untracked ファイルがあります。worktree と一緒に失われます。")
    case .unknown: warnings.append("未commit の変更があるかを確認できませんでした。")
    case .absent: break
    }
    switch inspection.ignoredFiles {
    case .present:
      warnings.append("gitignore 済みのファイル (.env など) があります。git はこれを確認せずに worktree ごと削除します。")
    case .unknown: warnings.append("gitignore 済みのファイルがあるかを確認できませんでした。")
    case .absent: break
    }
    switch inspection.unpushedCommits {
    case .present: warnings.append("push していない commit があります (upstream が無いか、upstream より先行しています)。")
    // §3.4: 「追跡先が消えた」と読める文言にしない。未 push のまま upstream だけ設定した場合もここへ来る。
    case .aheadUnknownWithoutTrackingReference:
      warnings.append("upstream は設定されていますが追跡 ref が無く、先行しているか判定できません。")
    case .unknown: warnings.append("push していない commit があるかを確認できませんでした。")
    case .absent, .notApplicable: break
    }
    switch inspection.branchMerge {
    case .unmerged: warnings.append("既定 branch \(defaultBranchName) へマージされていません。")
    case .unknown: warnings.append("既定 branch へマージ済みかを判定できません: \(mergeUnknownReason)")
    case .merged, .notApplicable: break
    }
    return warnings
  }

  /// 選択肢4で squash merge と判定したときに明示する一文 (§3.4、確定 2026-10-08)。
  var squashDeletionNotice: String? {
    guard case .merged(.squash, _) = safety.report.inspection.branchMerge else { return nil }
    return "git はこの branch を未マージと見なしているが、squash merge と判定したため強制削除する。"
  }

  func requiresAcknowledgement(_ option: WorktreeCloseOption) -> Bool {
    guard option.removesWorktree else { return false }
    return !removalWarnings.isEmpty || (option == .deleteBranch && squashDeletionNotice != nil)
  }

  /// `acknowledged` は警告を見たうえで続行を選んだか。警告が無いときは読まない。
  func plan(
    _ option: WorktreeCloseOption, acknowledged: Bool
  ) throws(WorktreeClosePlanError) -> WorktreeClosePlan {
    let confirmation: WorktreeRemovalConfirmation? =
      option.removesWorktree
      ? WorktreeRemovalConfirmation(
        report: safety.report,
        continuation: acknowledged && !removalWarnings.isEmpty
          ? .forcingAcknowledgedWarnings : .withoutForce)
      : nil
    return try planWorktreeClose(
      worktree: target, progress: progress.report, choice: option.choice,
      confirmation: confirmation)
  }

  private var defaultBranchName: String {
    safety.report.defaultBranch.branch.map { "「\($0)」" } ?? ""
  }

  private var mergeUnknownReason: String {
    if case .unresolved(let reason) = safety.report.defaultBranch {
      return reason.closeDescription
    }
    let failures = safety.failures.filter { $0.check == .branchMerge }
    return failures.isEmpty
      ? "git の答えを解釈できませんでした。"
      : failures.map(\.closeDescription).joined(
        separator: " / ")
  }

  private var branchDeletionUnavailability: String {
    let defaultBranch = safety.report.defaultBranch
    if target.branch?.hasPrefix("refs/") == true {
      return "branch 名が refs/ で始まるため、branch の削除は提供していません (Issue #142)。"
    }
    if case .unresolved(let reason) = defaultBranch {
      return "既定 branch を特定できないため、マージ済みか判定できません: \(reason.closeDescription)"
    }
    if let branch = target.branch, branch == defaultBranch.branch {
      return "この branch は既定 branch そのものです。"
    }
    switch safety.report.inspection.branchMerge {
    case .unmerged:
      return "既定 branch \(defaultBranchName) へマージされていないため、branch は削除できません。"
    case .unknown:
      return "既定 branch \(defaultBranchName) へマージ済みかを判定できないため、branch は削除できません: "
        + mergeUnknownReason
    case .merged, .notApplicable:
      return "branch を削除できる状態ではありません。"
    }
  }
}
