/// 検査結果を見たうえで続行を選んだ、という事実 (設計書 §3.4)。
///
/// §3.4 の検査結果は「実行を機械的に禁止する条件」ではなく「確認のうえ続行できる警告」である。
/// その確認をこの型が担い、削除を伴う計画 (`planWorktreeClose`) はこの値を必ず要求する。
/// したがって**検査結果を手にせずに `--force` を組み立てる経路は無い**。
///
/// - Important: 型で担保できるのはここまでである。`WorktreeCloseInspection` は public な
///   initializer を持つ値型なので、「本当に検査を実行したか」までは確かめられない。検査器だけが
///   作れる型にすればそこまで担保できるが、検査器は `Adapters` にあり、`TerminalCore` から
///   参照できない (docs/coding-guidelines.md §2.2 の依存方向)。
public struct WorktreeRemovalConfirmation: Sendable, Hashable {
  /// 警告を見たユーザーの選択。
  public enum Continuation: Sendable, Hashable {
    /// 警告を承知したうえで続行する。git が拒否する条件では `--force` が付く。
    case forcingAcknowledgedWarnings
    /// `--force` を付けずに実行する。git が拒否すればそこで Close は止まる。
    case withoutForce
  }

  public let inspection: WorktreeCloseInspection
  public let continuation: Continuation

  public init(inspection: WorktreeCloseInspection, continuation: Continuation) {
    self.inspection = inspection
    self.continuation = continuation
  }

  /// git 2.50.1 の実測では、`worktree remove` が拒否するのは変更ありまたは untracked がある場合
  /// だけで、`.gitignore` 済みのファイルしか無い worktree は `--force` 無しに rc=0 で、その
  /// ignored ファイルごと消える (§3.4 の表がこの検査を独立させている理由でもある)。
  /// そのため未commit検査が `absent` なら `--force` は付けない。要らない場面で付けても
  /// 消えるものは変わらず、「承知して続行した」という記録の意味だけが薄まる。
  ///
  /// 検査に失敗した (`unknown`) 場合にも付けられるようにしてあるのは、付けられないと
  /// 「検査できない worktree は永久に削除できない」という機械的な禁止になり、§3.4 が
  /// 警告に留めた判断を実装が覆すことになるためである。
  public var forcesWorktreeRemoval: Bool {
    continuation == .forcingAcknowledgedWarnings && inspection.uncommittedChanges != .absent
  }
}

/// Close の後始末の実行単位 (設計書 §3.4)。
///
/// - Important: 実行は **session 終了 → worktree 削除 → branch 削除** の順で、途中で失敗しても
///   **巻き戻せない**。worktree を消した後に branch 削除が失敗しても worktree は戻らないので、
///   実行層はどこまで進んだかを呼び出し側へ返す (`Adapters` の `WorktreeCloseOutcome`)。
public enum WorktreeCloseStep: Sendable, Hashable {
  case terminateSession
  case removeWorktree(force: Bool)
  /// 短縮 local branch 名。`git branch -d` は完全修飾した形を受け付けない
  /// (git 2.50.1 実測: `branch -d refs/heads/x` は rc=1 `error: branch 'refs/heads/x' not found`)。
  case deleteBranch(name: String)
}

/// `planWorktreeClose` でしか作れない。任意の step 列を組み立てて実行層へ渡す経路があると、
/// §3.4 が選択肢4へ課した「マージ済みであること」を実行層で迂回できてしまうため。
public struct WorktreeClosePlan: Sendable, Hashable {
  /// どの worktree の計画か。実行層はこれと自分の対象が一致しない計画を拒否する。
  ///
  /// 計画が対象を持たないと、worktree A の検査と続行確認から作った `--force` 付きの計画を
  /// worktree B の実行層へ渡せてしまい、**B は検査されていないのに消える**。同じ計画の
  /// `.deleteBranch` は B の Close として A の branch を消す。値そのものではなく、
  /// 「計画と実行の対象が同じであること」を確かめられるようにするために持つ。
  ///
  /// - Note: 「いつの検査か」(検査から実行までの間に worktree が変わる) はこの値では扱えない。
  public let worktree: WorktreeIdentity
  public let steps: [WorktreeCloseStep]

  // 明示的な access level が「検査を通っていない branch 削除を実行層へ渡せない」保証そのものになる。
  // swiftlint:disable:next unneeded_synthesized_initializer
  init(worktree: WorktreeIdentity, steps: [WorktreeCloseStep]) {
    self.worktree = worktree
    self.steps = steps
  }
}

public enum WorktreeClosePlanError: Error, Sendable, Hashable {
  /// 削除を伴う選択肢 (§3.4 の3・4) を、検査結果と続行確認なしに要求した。
  case removalNotConfirmed
  /// `isBranchDeletionAvailable` が許さない状態で選択肢4を要求した。選択肢3へ暗黙に格下げしない
  /// — 要求より少ない後始末を黙って行うのは、branch も消えたと信じている呼び出し側への嘘になる。
  case branchDeletionNotPermitted
}

/// 設計書 §3.4 の4択を実行単位へ落とす。
///
/// ここは Close の**計画**であり、tmux も git も撃たない (docs/coding-guidelines.md §2.2)。
/// 実行は `Adapters` の `WorktreeCloseExecutor` が行う。
///
/// - Important: **Inactive 化 (§3.2 の `WorktreeActivation`) はこの計画に含まれない。**
///   §3.4 の4択はどれも Inactive 化を伴うが、それは Terminal が持つ UI／運用状態の遷移であって
///   tmux や git への操作ではないため、`WorktreeActivation` 側の責務として分けてある。
///   したがって `.hideFromUI` が返す空の計画は「Close として何もしなくてよい」ではなく
///   「外部プロセスへ撃つものが無い」の意味であり、呼び出し側は空の計画でも Inactive 化を行う。
public func planWorktreeClose(
  worktree: WorktreeIdentity,
  choice: WorktreeCloseChoice,
  branch: String?,
  defaultBranch: DefaultBranchResolution,
  confirmation: WorktreeRemovalConfirmation?
) throws(WorktreeClosePlanError) -> WorktreeClosePlan {
  switch choice {
  case .hideFromUI:
    return WorktreeClosePlan(worktree: worktree, steps: [])
  case .terminateSession(.keepWorktree):
    return WorktreeClosePlan(worktree: worktree, steps: [.terminateSession])
  case .terminateSession(.removeWorktree(let afterRemoval)):
    guard let confirmation else { throw .removalNotConfirmed }
    var steps: [WorktreeCloseStep] = [
      .terminateSession, .removeWorktree(force: confirmation.forcesWorktreeRemoval),
    ]
    guard afterRemoval == .deleteBranch else {
      return WorktreeClosePlan(worktree: worktree, steps: steps)
    }
    guard
      let branch,
      isBranchDeletionAvailable(
        targetBranch: branch, defaultBranch: defaultBranch,
        merge: confirmation.inspection.branchMerge)
    else { throw .branchDeletionNotPermitted }
    steps.append(.deleteBranch(name: branch))
    return WorktreeClosePlan(worktree: worktree, steps: steps)
  }
}
