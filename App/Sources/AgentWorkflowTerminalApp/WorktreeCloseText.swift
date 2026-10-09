import Adapters
import TerminalCore

// Close の確認と結果に出す文言 (設計書 §3.4)。git の生の出力は1行目だけを添える —— 原因の
// 手掛かりにはなるが、全文は確認の画面に収まらない。

extension DefaultBranchResolution.UnresolvedReason {
  var closeDescription: String {
    switch self {
    case .originHeadMissing:
      "origin/HEAD が無く、Project Root の branch も分かりません。"
    case .invalidOriginHead(let value):
      "origin/HEAD の値を解釈できません (\(value))。"
    case .lookupFailed:
      "origin/HEAD を読めませんでした。"
    case .detachedHead:
      "HEAD が branch を指していません。"
    }
  }
}

extension GitCloseSafetyInspectionFailure {
  var closeDescription: String {
    switch reason {
    case .git(let error): error.closeDescription
    case .statusParse, .logParse: "git の出力を解釈できませんでした。"
    case .missingStatusBranch: "git status が branch の情報を返しませんでした。"
    case .invalidRevision(let revision): "revision として扱えない値です (\(revision))。"
    }
  }
}

extension GitRunnerError {
  var closeDescription: String {
    switch self {
    case .binaryNotFound: "git の実行ファイルが見つかりません。"
    case .invalidRepositoryDirectory(let url): "git を実行するディレクトリが不正です: \(url.path)"
    case .process(.timedOut): "git が時間内に終わりませんでした。"
    case .process(.cancelled): "取り消しました。"
    case .process(let error): "git を実行できませんでした: \(error)"
    case .commandFailed(let exitCode, _, let stderr):
      "git が失敗しました (exit \(exitCode)): \(firstLine(of: stderr))"
    }
  }
}

extension GitWorktreeProgressReadError {
  var closeDescription: String {
    switch self {
    case .git(let error): error.closeDescription
    case .unexpectedHeadOutput, .unexpectedTipOutput: "git の出力を解釈できませんでした。"
    case .invalidBranchName(let name): "branch 名を git へ渡せません (\(name))。"
    }
  }
}

extension WorktreeInProgressOperation {
  var closeDescription: String {
    switch self {
    case .merge: "merge"
    case .cherryPick: "cherry-pick"
    case .revert: "revert"
    case .rebase: "rebase"
    case .mailboxApply: "git am"
    case .bisect: "bisect"
    case .sequence: "連続した cherry-pick / revert"
    }
  }
}

func describe(_ operations: Set<WorktreeInProgressOperation>) -> String {
  WorktreeInProgressOperation.allCases.filter(operations.contains).map(\.closeDescription)
    .joined(separator: "・")
}

/// 計画段階で Close 全体を拒否したときの理由と、ユーザーにできること。
struct WorktreeCloseRefusalText {
  let reason: String
  let guidance: String

  init(_ error: WorktreeClosePlanError, progressFailure: GitWorktreeProgressReadError?) {
    switch error {
    case .detachedHeadIsNotClosable:
      reason = "HEAD が branch を指していません (detached HEAD)。"
      guidance = "branch を作るか、進行中の rebase / merge を完了してから Close してください。"
    case .operationInProgress(let operations):
      reason = "作業の途中です: \(describe(operations))"
      guidance = "途中の操作を完了または中止してから Close してください。"
    case .operationProgressUnknown:
      reason =
        "作業の途中かどうかを確認できませんでした"
        + (progressFailure.map { ": \($0.closeDescription)" } ?? "。")
      guidance = "確認できない間は Close できません。時間をおいて再検査してください。"
    case .projectRootIsNotClosable:
      reason = "Project Root は Close できません。"
      guidance = ""
    case .removalNotConfirmed, .confirmationIsForAnotherWorktree, .branchDeletionNotPermitted,
      .progressReportIsForAnotherWorktree:
      reason = "Close の計画を立てられませんでした: \(error)"
      guidance = "再検査してください。"
    }
  }
}

extension WorktreeClosePreflightRefusal {
  var closeDescription: String {
    switch self {
    case .detachedHead:
      "HEAD が branch を指していません (detached HEAD)。"
    case .branchChanged(let planned, let current):
      "HEAD が「\(planned)」から「\(current)」へ切り替わっています。"
    case .operationInProgress(let operations):
      "作業の途中になっています: \(describe(operations))"
    case .branchTipMoved(let planned, let current):
      "branch の先端が検査の後に動きました (\(short(planned)) → \(short(current)))。"
    case .observationFailed(let error):
      "状態を読み直せませんでした: \(error.closeDescription)"
    }
  }
}

extension WorktreeCloseStep {
  var closeDescription: String {
    switch self {
    case .terminateSession: "tmux session の終了"
    case .removeWorktree(let force): force ? "worktree の削除 (--force)" : "worktree の削除"
    case .deleteBranch(let name, _): "branch「\(name)」の削除 (git branch -D)"
    }
  }
}

extension WorktreeCloseStepFailure.Reason {
  var closeDescription: String {
    switch self {
    case .tmux(let error):
      "tmux session を終了できませんでした: \(error)"
    case .git(let error):
      error.closeDescription
    case .worktreeRemoval(let error, let registration):
      "\(error.closeDescription) \(registration.closeDescription)"
    case .branchTipMoved(let planned, let current):
      "branch -D の直前に先端が動いていた (\(short(planned)) → \(short(current))) ため、branch は削除せずに残しました。"
    case .branchTipUnverified(let error):
      "branch -D の直前に先端を確かめられなかったため、branch は削除せずに残しました: \(error.closeDescription)"
    case .invalidArguments:
      "branch 名を git へ渡せる形にできなかったため、branch は削除していません。"
    }
  }
}

extension WorktreeRegistrationAfterFailedRemoval {
  var closeDescription: String {
    switch self {
    case .retained:
      "worktree の登録は残っています。原因を取り除いてから、もう一度 Close できます。"
    case .retainedButNotScannable:
      "登録は残っていますが git が prunable と見なしており、作業ツリーは消えている可能性があります。"
    case .dropped:
      "worktree の登録が一覧に見えなくなりました。作業ツリーが一部残っている可能性があります。"
    case .unknown(let error):
      "登録が残っているかを読み直せませんでした: \(error.closeDescription)"
    }
  }
}

extension WorktreeCloseExecutorError {
  var closeDescription: String {
    switch self {
    case .worktreePathNotAbsolute(let path): "worktree のパスが絶対パスではありません: \(path)"
    case .repositoryDirectoryIsTheRemovedWorktree(let url):
      "git を実行するディレクトリが削除対象の worktree です: \(url.path)"
    case .git(let error): error.closeDescription
    }
  }
}

private func short(_ commit: CommitObjectID) -> String {
  String(commit.rawValue.prefix(10))
}

private func firstLine(of text: String) -> String {
  text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
}
