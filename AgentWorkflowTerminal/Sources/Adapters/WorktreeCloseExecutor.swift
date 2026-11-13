import Foundation
import TerminalCore

public struct WorktreeCloseStepFailure: Error, Sendable, Equatable {
  public enum Reason: Sendable, Equatable {
    case tmux(TmuxSessionOperationError)
    case orphanedTmuxServer(socketPath: String, TmuxOrphanedServerProbeResult)
    /// `branch --delete` の失敗。こちらは失敗すれば branch は残っており、読み直す対象が無い。
    case git(GitRunnerError)
    /// `worktree remove` の失敗。**「失敗した」だけでは何が起きたか決まらない**ので、
    /// 登録を読み直した結果を必ず添える (`WorktreeRegistrationAfterFailedRemoval`)。
    case worktreeRemoval(GitRunnerError, registration: WorktreeRegistrationAfterFailedRemoval)
    /// `branch -D` の直前 (worktree 削除の後) に読み直した先端が、マージ判定のときと違った。
    /// `-D` は撃っておらず、branch は残っている。判定の後に積まれた commit はマージ済みと
    /// 確かめられていない (§3.4、Issue #359)。
    case branchTipMoved(planned: CommitObjectID, current: CommitObjectID)
    /// `branch -D` の直前に先端を読めなかった。動いていないと確かめられないので `-D` は撃って
    /// おらず、branch は残っている。
    case branchTipUnverified(GitWorktreeProgressReadError)
    /// step の値から git の argv を組み立てられなかった。作業ツリーのパスは
    /// `WorktreeCloseExecutor.init` が弾くので、ここへ来るのは `DetectedWorktree` から来た
    /// branch 名が `GitCloseWriteCommand.deleteMergedBranch` の受け付ける形でなかったときだけ
    /// である (`isBranchDeletionAvailable` の暫定 guard はこれより緩い。Issue #142)。
    case invalidArguments
  }

  public let step: WorktreeCloseStep
  public let reason: Reason
}

/// `WorktreeCloseExecutor` を構築できない理由。
public enum WorktreeCloseExecutorError: Error, Sendable, Equatable {
  /// `GitCloseWriteCommand.removeWorktree` は絶対パスしか受け付けない。実行時ではなく構築時に
  /// 弾くのは、実行時に弾くと **`terminateSession` を撃った後**で `.invalidArguments` を返す
  /// ことになるためである。session 終了は巻き戻せない。
  case worktreePathNotAbsolute(String)
  case repositoryDirectoryIsTheRemovedWorktree(URL)
  case git(GitRunnerError)
}

/// 計画と実行層の対象が食い違っている。
///
/// これを弾かないと、worktree A の検査と続行確認から作った `--force` 付きの計画を worktree B の
/// 実行層へ渡せてしまい、**B は検査されていないのに消える**。
public struct WorktreeClosePlanMismatch: Error, Sendable, Equatable {
  public let plan: WorktreeIdentity
  public let executor: WorktreeIdentity
}

/// `execute` の結果。中止 (1 step も撃っていない) と、step を撃ち始めた後の失敗を型で分ける。
public enum WorktreeCloseExecution: Sendable, Equatable {
  /// 実行直前の読み直しで中止した。tmux にも git にも書き込んでいない。
  case abandoned(WorktreeClosePreflightRefusal)
  case executed(WorktreeCloseOutcome)
}

/// どこまで進んだか。Close の後始末は**巻き戻せない**ので、「全部成功か例外か」の2値にしない
/// (設計書 §3.4)。
public struct WorktreeCloseOutcome: Sendable, Equatable {
  /// 成功した step。計画順。
  public let completed: [WorktreeCloseStep]
  /// 最初の失敗。`nil` なら全 step が成功した。
  ///
  /// - Important: 失敗は「その step で何も起きていない」を意味しない。step 自体が atomic とは
  ///   限らないためで、`worktree remove` については `Reason.worktreeRemoval` が添える登録の
  ///   読み直し結果まで見ないと、やり直せるのか検出不能になったのかが決まらない。
  public let failure: WorktreeCloseStepFailure?
  /// 失敗したため実行しなかった step。
  public let skipped: [WorktreeCloseStep]
}

/// `planWorktreeClose` が作った計画を、tmux と git へ撃つ (設計書 §3.4)。
///
/// - Important: `repositoryDirectory` は**消す worktree の中を指してはならない**。git 2.50.1 の
///   実測では、`git -C <消した worktree> branch -d <名前>` は rc=128 の
///   `fatal: cannot change to '<path>': No such file or directory` になる。`worktree remove` 自体は
///   自分自身を `-C` に指しても rc=0 で通るので、失敗するのは後続の branch 削除だけであり、
///   しかもその時点で worktree はもう戻らない。通常は Project Root の作業ツリーを渡す。
/// - Note: 計画の順序 (session 終了 → worktree 削除 → branch 削除) は `WorktreeClosePlan` が
///   決める。この型は順に撃ち、最初の失敗でそれ以降を実行しない。
public struct WorktreeCloseExecutor: Sendable {
  private let identity: WorktreeIdentity
  private let worktreePath: String
  private let sessionOperations: TmuxSessionOperations
  private let orphanedServerProbe: TmuxOrphanedServerProbe
  private let runner: GitCloseWriteRunner
  /// `worktree remove` の失敗後に登録を読み直すためだけに持つ。`GitCloseWriteRunner` と別なのは、
  /// あちらが `GitCloseWriteCommand` しか受け付けない —— それが「この層は2つの書き込みしか
  /// 撃てない」保証そのもの —— であり、読み取り用の command を通せないためである。同じ規則を
  /// 書き写すのではなく `GitRunner` をそのまま使う (Issue #143)。
  private let readRunner: GitRunner
  /// 実行直前の読み直し用。`readRunner` (`repositoryDirectory` で動く) とは別に、対象の管理
  /// ディレクトリで動く。`repositoryDirectory` で `symbolic-ref HEAD` を撃つと、答えるのは
  /// 対象ではなく Project Root の HEAD である。
  private let progressReader: GitWorktreeProgressReader
  /// `force` は計画ごとに変わるが、`removeWorktree(path:force:)` が `nil` を返すかどうかはパスの
  /// 形だけで決まる。両方を init で組み立てておくと、**実行時に `nil` を扱う分岐が残らない** ——
  /// 「撃っていない step を成功として報告する」経路を、テストで到達できないまま置かずに済む。
  private let unforcedRemoval: GitCloseWriteCommand
  private let forcedRemoval: GitCloseWriteCommand

  /// 消す対象を安定 ID と作業ツリーのパスに分けて受け取らず、`DetectedWorktree` ごと受け取るのは、
  /// この2つが**同じスキャン結果の同じ1件から来たこと**を型で担保するためである。別々に受け取ると
  /// worktree A の ID と worktree B の作業ツリーのパスを組にでき、計画と実行層の対象照合
  /// (`execute`) が通ったうえで B が消える —— 照合が防ごうとしている事故が一段下で復活する。
  /// 安定 ID だけで足りないのは、`WorktreeIdentity` が**管理ディレクトリ**のパスであって
  /// `worktree remove` へ渡す作業ツリーのパスではないためである (設計書 §3.5)。
  ///
  /// - Important: **tmux session 名も同じ理由で引数に取らない。** §3.5 は session 名を安定 ID
  ///   だけから決定的に導出すると確定しており、外から渡す正当な理由が無い一方、渡せるようにすると
  ///   worktree A と session B を組にできる。tmux 3.4 実測では
  ///   `kill-session -t "=awt-feature-b-e7b88064"` はその名前の session だけを rc=0 で落とし、
  ///   もう一方の session は残る。つまり組にした場合、対象照合を通過したうえで **B の session を
  ///   殺してから A の worktree を消す**という順で完走する。
  ///
  /// - Throws: 作業ツリーのパスが `GitCloseWriteCommand` の受け付ける形でないとき、
  ///   `repositoryDirectory` が消す worktree そのものだったとき、git を起動できないとき。
  public init(
    repositoryDirectory: URL,
    worktree: DetectedWorktree,
    sessionOperations: TmuxSessionOperations,
    orphanedServerProbe: TmuxOrphanedServerProbe? = nil,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(WorktreeCloseExecutorError) {
    try self.init(
      repositoryDirectory: repositoryDirectory, worktree: worktree,
      sessionOperations: sessionOperations, orphanedServerProbe: orphanedServerProbe,
      processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) },
      fileExists: { FileManager.default.fileExists(atPath: $0) })
  }

  init(
    repositoryDirectory: URL,
    worktree: DetectedWorktree,
    sessionOperations: TmuxSessionOperations,
    orphanedServerProbe: TmuxOrphanedServerProbe? = nil,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool,
    fileExists: @escaping @Sendable (String) -> Bool,
    isDirectory: @escaping @Sendable (String) -> Bool = GitWorktreeProgressReader.directoryExists,
    readFile: @escaping @Sendable (String) throws -> String = {
      try String(contentsOfFile: $0, encoding: .utf8)
    }
  ) throws(WorktreeCloseExecutorError) {
    // `DetectedWorktree.worktreePath` は壊れた `worktree list` の出力で一覧全体を落とさないよう
    // 意図的に無検証で通されている (あちらの doc コメント)。検証はここで行う。条件を
    // `hasPrefix("/")` として書き写さず command を組み立ててみるのは、受け入れ条件を
    // `GitCloseWriteCommand` 側の1か所に留め、構築時の検証と実行時の argv が割れないようにするため。
    guard
      let unforcedRemoval = GitCloseWriteCommand.removeWorktree(
        path: worktree.worktreePath, force: false),
      let forcedRemoval = GitCloseWriteCommand.removeWorktree(
        path: worktree.worktreePath, force: true)
    else {
      throw .worktreePathNotAbsolute(worktree.worktreePath)
    }
    // 消す worktree をそのまま渡す取り違えだけを弾く。`repositoryDirectory` が worktree の
    // **配下**にある場合は捕まえられず、そこは呼び出し側の責務として doc コメントに残す。
    guard repositoryDirectory.path != worktree.worktreePath else {
      throw .repositoryDirectoryIsTheRemovedWorktree(repositoryDirectory)
    }
    self.identity = worktree.identity
    self.worktreePath = worktree.worktreePath
    self.unforcedRemoval = unforcedRemoval
    self.forcedRemoval = forcedRemoval
    self.sessionOperations = sessionOperations
    self.orphanedServerProbe = orphanedServerProbe ?? TmuxOrphanedServerProbe(runner: processRunner)
    do {
      self.runner = try GitCloseWriteRunner(
        repositoryDirectory: repositoryDirectory, processRunner: processRunner,
        executableCandidates: executableCandidates, parentEnvironment: parentEnvironment,
        isExecutableFile: isExecutableFile)
      self.readRunner = try GitRunner(
        repositoryDirectory: repositoryDirectory, processRunner: processRunner,
        executableCandidates: executableCandidates, parentEnvironment: parentEnvironment,
        isExecutableFile: isExecutableFile)
      self.progressReader = GitWorktreeProgressReader(
        runner: try GitRunner(
          repositoryDirectory: URL(fileURLWithPath: worktree.identity.rawValue),
          processRunner: processRunner, executableCandidates: executableCandidates,
          parentEnvironment: parentEnvironment, isExecutableFile: isExecutableFile),
        worktreeRunner: try GitRunner(
          repositoryDirectory: URL(fileURLWithPath: worktree.worktreePath),
          processRunner: processRunner, executableCandidates: executableCandidates,
          parentEnvironment: parentEnvironment, isExecutableFile: isExecutableFile),
        identity: worktree.identity, worktreePath: worktree.worktreePath,
        fileExists: fileExists, isDirectory: isDirectory, readFile: readFile)
    } catch {
      throw .git(error)
    }
  }

  /// 計画段階の拒否を、最初の step を撃つ前にもう一度判定する (§3.4、Issue #354)。worktree を
  /// 削除しない計画 (選択肢2) は途中状態だけを読み直し、detached や計画時と別の branch では中止
  /// しない —— 何も消さないため (§3.4、2026-11-13)。worktree 削除を含む計画では HEAD・lock・
  /// submodule も読み直し、計画から実行までの間に detached になった worktree の削除や、session
  /// 終了後の削除失敗、`--force` で submodule ごと消えることを防ぐ。branch 削除を含む計画では
  /// 先端も照合し、判定後に積まれた commit を巻き込まない (Issue #359)。
  ///
  /// - Note: 空の計画 (選択肢1) では読み直さない。撃つものが無く、中止しても止める操作が無い。
  ///   §3.4 の拒否は計画段階 (`planWorktreeClose`) で選択肢1にも掛かっている。
  /// - Throws: 計画が別の worktree のものだったとき。実行前に弾く —— 1 step でも撃ってからでは
  ///   巻き戻せない。
  public func execute(
    _ plan: WorktreeClosePlan
  ) async throws(WorktreeClosePlanMismatch) -> WorktreeCloseExecution {
    guard plan.worktree == identity else {
      throw WorktreeClosePlanMismatch(plan: plan.worktree, executor: identity)
    }
    guard !plan.steps.isEmpty else {
      return .executed(WorktreeCloseOutcome(completed: [], failure: nil, skipped: []))
    }
    let plannedTip = plan.steps.lazy.compactMap { step -> CommitObjectID? in
      guard case .deleteBranch(_, let tip) = step else { return nil }
      return tip
    }.first
    if let refusal = await progressReader.preflightRefusal(
      plannedBranch: plan.branch, plannedTip: plannedTip,
      removesWorktree: plan.steps.contains {
        if case .removeWorktree = $0 { return true }; return false
      })
    {
      return .abandoned(refusal)
    }
    var completed: [WorktreeCloseStep] = []
    for (index, step) in plan.steps.enumerated() {
      guard let failure = await perform(step) else {
        completed.append(step)
        continue
      }
      return .executed(
        WorktreeCloseOutcome(
          completed: completed, failure: failure,
          skipped: Array(plan.steps[plan.steps.index(after: index)...])))
    }
    return .executed(WorktreeCloseOutcome(completed: completed, failure: nil, skipped: []))
  }

  private func perform(_ step: WorktreeCloseStep) async -> WorktreeCloseStepFailure? {
    switch step {
    case .terminateSession:
      await terminateSession(step)
    case .removeWorktree(let force):
      await removeWorktree(force: force, for: step)
    case .deleteBranch(let name, let tip):
      await deleteBranch(name: name, plannedTip: tip, for: step)
    }
  }

  /// 先端の照合は `execute` の冒頭 (session 終了の前) でも行うが、session を終了するまで Agent は
  /// 動いており、その間に積まれた commit は冒頭の照合をすり抜ける (レビューの実測: 計画時の先端の
  /// 後に commit → `worktree remove` rc=0 → `branch --delete --force` がその commit ごと消した)。
  /// だから `-D` の直前にもう一度読む。worktree はもう無いので `repositoryDirectory` で読む。
  /// 残る窓は、ここで読んでから `-D` を撃つまでである。
  private func deleteBranch(
    name: String, plannedTip: CommitObjectID, for step: WorktreeCloseStep
  ) async -> WorktreeCloseStepFailure? {
    guard let command = GitCloseWriteCommand.deleteMergedBranch(name: name) else {
      return WorktreeCloseStepFailure(step: step, reason: .invalidArguments)
    }
    do {
      let current = try await readLocalBranchTip(name, with: readRunner)
      guard current == plannedTip else {
        return WorktreeCloseStepFailure(
          step: step, reason: .branchTipMoved(planned: plannedTip, current: current))
      }
    } catch {
      return WorktreeCloseStepFailure(step: step, reason: .branchTipUnverified(error))
    }
    return await write(command, for: step)
  }

  /// 失敗したときだけ `worktree list` を1回読み直す。書き込みの失敗後に読み取りを撃つのは
  /// この層の責務である —— §3.4 が「git の失敗に任せるだけでは安全確認にならない」と言うのと
  /// 同じ理由で、**git の exit code だけでは何が起きたかが決まらない**。
  ///
  /// - Important: 読み直すだけで、`worktree prune` などで**直さない**。回復は別の設計判断を含む。
  private func removeWorktree(
    force: Bool, for step: WorktreeCloseStep
  ) async -> WorktreeCloseStepFailure? {
    do {
      _ = try await runner.run(force ? forcedRemoval : unforcedRemoval)
      return nil
    } catch {
      return WorktreeCloseStepFailure(
        step: step, reason: .worktreeRemoval(error, registration: await registration()))
    }
  }

  /// - Note: 突き合わせは `DetectedWorktree.worktreePath` と `worktree list --porcelain` の
  ///   `worktree` 行を **UTF-8 バイト列**で比べる。`String` の `==` は Unicode の正準等価を見るので
  ///   `caf\u{00E9}` と `cafe\u{0301}` を等しいと答えるが (実測: `String ==` は `true`、
  ///   UTF-8 バイト列は `false`)、その向きは**偽 `.retained`** —— 消えた登録を残っていると読ませる。
  ///   `WorktreeIdentity` が同じ理由でバイト列比較を選んでいるので、粒度をそちらへ揃える。
  ///   アプリ側で正規化もしない (`WorktreeIdentity` の doc コメントと同じ理由)。
  /// - Note: 解釈できなかった record があっても `dropped` の判定は曇らない。`GitWorktreeList` が
  ///   record を落とすのは `worktree ` 行そのものが無いときだけで、探しているパスを持つ record は
  ///   定義上そこに含まれない。
  /// - Important: `prunable` / bare を落とす条件は `GitWorktreeDetector.isScannable` と同じもので、
  ///   あちらが `private static` なため書き写している。**片方だけを変えると、この層の答えと
  ///   実際にスキャンへ載るかが割れる** —— それがこの3分類が閉じようとしている欠陥そのものである。
  private func registration() async -> WorktreeRegistrationAfterFailedRemoval {
    do {
      let result = try await readRunner.run(.worktreeList())
      let entries = GitWorktreeList.parse(output: result.stdout).entries
      guard let entry = entries.first(where: { $0.path.utf8.elementsEqual(worktreePath.utf8) })
      else { return .dropped }
      return entry.prunableReason == nil && !entry.isBare ? .retained : .retainedButNotScannable
    } catch {
      return .unknown(error)
    }
  }

  /// `TmuxSessionOperations.kill` は「もう無かった」を成功へ丸めず、どちらを成功と見なすかを
  /// Close の選択肢へ委ねている。**Close は `sessionNotFound` / `serverNotRunning` を
  /// 成功とする**。選択肢2〜4 が求めているのは「この worktree の
  /// session がもう無いこと」であり、session 不在と server 停止はその結果を満たしている。
  /// socket 欠落は生存中の server でも起き、session 不在の証拠にはならない (Issue #492 で計測)。
  /// 一覧と終了のどちらで socket 欠落が出ても lsof で probe し、不在を確定できた場合だけ続ける
  /// (一覧なら空の一覧として番号1の終了へ進む)。取り残された server が
  /// ある場合と確かめられない場合は、Agent が動いたまま worktree を消さないよう失敗にする
  /// (Issue #500、Director 決定3、2026-11-02)。
  /// session 不在や server 停止を失敗にすると、session が先に消えた worktree では
  /// 選択肢3・4 が二度と完了できず、
  /// 途中まで進んだ Close をやり直すこともできない —— 実行は巻き戻せないので、やり直しは
  /// 必要な操作である。
  ///
  /// tmux 3.4 実測: 稼働中 server で存在しない session は rc=1 `can't find session: <名前>`、
  /// server 停止後 (socket は残存) は rc=1 `no server running on <path>`、socket が無ければ
  /// rc=1 `error connecting to <path> (No such file or directory)`。後者は未起動だけでなく、
  /// 生存中の server の socket が消えた場合も含む (tmux 3.8、Issue #492 で計測)。
  ///
  /// 不在と確認できない失敗は畳まない。他の接続失敗も
  /// 分類できない失敗も「session が無い」証拠には
  /// ならず、agent プロセスが動いたまま worktree を消しにいくことになるためである。
  /// 一覧取得の失敗も同じ理由で停止する。§3.4 の Close は接尾辞付きもすべて終了する。
  /// 番号1は一覧取得直後に作られる場合もあるため、一覧に無くても従来どおり終了を試みる。
  private func terminateSession(_ step: WorktreeCloseStep) async -> WorktreeCloseStepFailure? {
    do {
      let names: [String]
      do {
        names = try await sessionOperations.list()
      } catch .serverSocketMissing(let socketPath) {
        if let failure = await failureUnlessServerAbsent(socketPath: socketPath, step: step) {
          return failure
        }
        names = []
      }
      let indices = Set(TmuxSessionName.indices(of: identity, in: names)).union([1]).sorted()
      for index in indices {
        guard let key = TerminalSessionKey(identity: identity, index: index) else { continue }
        do {
          try await sessionOperations.kill(session: TmuxSessionName(key: key))
        } catch .sessionNotFound, .serverNotRunning {
          continue
        } catch .serverSocketMissing(let socketPath) {
          if let failure = await failureUnlessServerAbsent(socketPath: socketPath, step: step) {
            return failure
          }
        }
      }
      return nil
    } catch {
      return WorktreeCloseStepFailure(step: step, reason: .tmux(error))
    }
  }

  private func failureUnlessServerAbsent(
    socketPath: String, step: WorktreeCloseStep
  ) async -> WorktreeCloseStepFailure? {
    let result = await orphanedServerProbe.probe(socketPath: socketPath)
    switch result {
    case .absent: return nil
    case .orphaned, .undetermined:
      return WorktreeCloseStepFailure(
        step: step, reason: .orphanedTmuxServer(socketPath: socketPath, result))
    }
  }

  private func write(
    _ command: GitCloseWriteCommand, for step: WorktreeCloseStep
  ) async -> WorktreeCloseStepFailure? {
    do {
      _ = try await runner.run(command)
      return nil
    } catch {
      return WorktreeCloseStepFailure(step: step, reason: .git(error))
    }
  }
}
