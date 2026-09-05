import Foundation
import TerminalCore

/// Close の後始末だけを表現する git の**書き込み** command (設計書 §3.4 / §17.2)。
///
/// 「Git は読み取り中心で書き込みを持たない」の唯一の例外がここであり、例外を例外のまま
/// 留めるために3つの制約を置く。
///
/// 1. `GitReadCommand` に書き込み case を足さない。あちらの internal initializer が
///    「モジュール外から書き込み command を作れない」保証そのものなので、そこへ混ぜると
///    保証している対象が変わってしまう。
/// 2. 作れるのは `worktree remove` と `branch -d` の2つだけ。private initializer により、
///    任意の subcommand を組み立てる経路は無い。
/// 3. `Adapters` の外へ出さない。公開している実行の入口は `WorktreeCloseExecutor.execute(_:)`
///    だけで、そこへ渡せる `WorktreeClosePlan` は `planWorktreeClose` しか作れない。
struct GitCloseWriteCommand: Sendable, Equatable {
  let arguments: [String]

  private init(arguments: [String]) {
    self.arguments = arguments
  }

  /// - Parameters:
  ///   - path: 消す作業ツリーの絶対パス。`git worktree list --porcelain` は作業ツリーの絶対パス
  ///     しか吐かない (`GitWorktreeDetector` の doc コメント)。
  ///   - force: 検査結果を見たうえでの続行確認から導く (`WorktreeRemovalConfirmation`)。
  /// - Returns: 絶対パスでなければ `nil`。
  static func removeWorktree(path: String, force: Bool) -> Self? {
    guard path.hasPrefix("/") else { return nil }
    // `--` を置くのは `-` で始まるパスが option として食われないため
    // (git 2.50.1 実測: `worktree remove -- <path>` は rc=0 で消える)。
    return Self(arguments: ["worktree", "remove"] + (force ? ["--force"] : []) + ["--", path])
  }

  /// **`-D` は持たない。** §3.4 は選択肢4をマージ済み branch に限る。`-d` の拒否
  /// (git 2.50.1 実測: rc=1 / `error: the branch 'topic' is not fully merged`) は、こちらの
  /// 未merge検査と git の判断が食い違ったという信号であって、押し通す対象ではない。
  ///
  /// - Parameter name: 短縮 local branch 名。`refs/` 始まりを弾くのは、`branch -d` が完全修飾した
  ///   形も `refs/` 始まりの値も rc=1 の `not found` にするためで (git 2.50.1 実測)、argv の形の
  ///   検証である。同じ前置を見る Issue #142 の暫定 guard (`isBranchDeletionAvailable`) とは
  ///   目的が別で、そちらは選択肢4を提供するかどうかを決める。
  /// - Returns: 短縮 local branch 名でなければ `nil`。
  static func deleteMergedBranch(name: String) -> Self? {
    guard !name.isEmpty, !name.hasPrefix("refs/") else { return nil }
    return Self(arguments: ["branch", "--delete", "--", name])
  }
}

/// Close の後始末の git 書き込みだけを撃つ。
///
/// - Important: 実行ファイルの解決と子プロセスへ渡す環境は `GitRunner` と同じ規則で組み立てる。
///   同じ規則が2か所にあるのは、`GitRunner` 側の該当メンバが `private` で、別ファイルからは
///   参照できないためである。**片方だけを変えると git の起動条件が読み取りと書き込みで割れる。**
struct GitCloseWriteRunner: Sendable {
  /// 作業ツリーの実削除に掛かる時間はファイル数に比例する。git 2.50.1 の実測では、ignored な
  /// 30,000ファイルを持つ worktree の `worktree remove` が 1.9 秒だった。読み取り用の
  /// `GitRunner.defaultTimeout` (30秒) は約50万ファイル相当で尽きる一方、途中で打ち切ると
  /// 半分消えた worktree が残り、それは巻き戻せない。読み取りより長く待つ。
  static let defaultTimeout = Duration.seconds(120)

  private let repositoryDirectory: URL
  private let processRunner: any ProcessRunning
  private let executableURL: URL
  private let environment: [String: String]

  init(
    repositoryDirectory: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
  ) throws(GitRunnerError) {
    guard repositoryDirectory.isFileURL, repositoryDirectory.baseURL == nil,
      repositoryDirectory.path.hasPrefix("/")
    else {
      throw .invalidRepositoryDirectory(repositoryDirectory)
    }
    guard let executableURL = executableCandidates.first(where: isExecutableFile) else {
      throw .binaryNotFound(candidates: executableCandidates)
    }
    self.repositoryDirectory = repositoryDirectory
    self.processRunner = processRunner
    self.executableURL = executableURL
    var environment = ["LC_ALL": "C"]
    for key in ["HOME", "PATH"] where parentEnvironment[key] != nil {
      environment[key] = parentEnvironment[key]
    }
    self.environment = environment
  }

  func run(_ command: GitCloseWriteCommand) async throws(GitRunnerError) -> ProcessRunResult {
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: executableURL,
        arguments: ["--no-optional-locks", "-C", repositoryDirectory.path, "--no-pager"]
          + command.arguments,
        environment: environment, timeout: Self.defaultTimeout,
        outputLimit: GitRunner.defaultOutputLimit)
    } catch { throw .process(error) }
    guard result.exitCode == 0 else {
      throw .commandFailed(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }
    return result
  }
}

/// `worktree remove` が失敗した後、登録が残っているかを読み直した結果 (設計書 §3.4)。
///
/// **`worktree remove` は step として atomic ではない。** git 2.50.1 実測では、clean な worktree の
/// サブディレクトリを `chmod 500` にすると `worktree remove` は
/// `error: failed to delete '<path>': Permission denied` と **rc=255** で終わるが、
/// `worktree list --porcelain` からその worktree は消え、管理ディレクトリ (`.git/worktrees/<名前>`)
/// ごと削除されていた。作業ツリーのディレクトリは中途半端に消えた状態で残る (`--force` を付けても
/// 同じ)。一方、未commit変更があって git が実行を拒否した場合は rc=128 で登録は残る。
/// **exit code だけでは区別できない**ので、この層が読み取りを1回撃って確かめる。
public enum WorktreeRegistrationAfterFailedRemoval: Sendable, Equatable {
  /// 登録が残っている。`GitWorktreeDetector.scan()` は今までどおりこの worktree を返し、
  /// Close をやり直せる。
  case retained
  /// 登録が消えている。`scan()` は `worktree list` しか見ないので**以後この worktree は
  /// アプリから検出されない**。Active/Inactive を失い、Close をやり直す経路も無くなる一方、
  /// ディスクにはユーザーのファイルが残る。
  case dropped
  /// 読み直し自体が失敗し、どちらか決められなかった。`retained` へ丸めない —— 消えた登録を
  /// 「何も起きていない」と読ませることが、この読み直しが防ごうとしている事故そのものである。
  case unknown(GitRunnerError)
}

public struct WorktreeCloseStepFailure: Error, Sendable, Equatable {
  public enum Reason: Sendable, Equatable {
    case tmux(TmuxSessionOperationError)
    /// `branch --delete` の失敗。こちらは失敗すれば branch は残っており、読み直す対象が無い。
    case git(GitRunnerError)
    /// `worktree remove` の失敗。**「失敗した」だけでは何が起きたか決まらない**ので、
    /// 登録を読み直した結果を必ず添える (`WorktreeRegistrationAfterFailedRemoval`)。
    case worktreeRemoval(GitRunnerError, registration: WorktreeRegistrationAfterFailedRemoval)
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
  private let session: TmuxSessionName
  private let sessionOperations: TmuxSessionOperations
  private let runner: GitCloseWriteRunner
  /// `worktree remove` の失敗後に登録を読み直すためだけに持つ。`GitCloseWriteRunner` と別なのは、
  /// あちらが `GitCloseWriteCommand` しか受け付けない —— それが「この層は2つの書き込みしか
  /// 撃てない」保証そのもの —— であり、読み取り用の command を通せないためである。同じ規則を
  /// 書き写すのではなく `GitRunner` をそのまま使う (Issue #143)。
  private let readRunner: GitRunner
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
  /// - Throws: 作業ツリーのパスが `GitCloseWriteCommand` の受け付ける形でないとき、
  ///   `repositoryDirectory` が消す worktree そのものだったとき、git を起動できないとき。
  public init(
    repositoryDirectory: URL,
    worktree: DetectedWorktree,
    session: TmuxSessionName,
    sessionOperations: TmuxSessionOperations,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(WorktreeCloseExecutorError) {
    try self.init(
      repositoryDirectory: repositoryDirectory, worktree: worktree, session: session,
      sessionOperations: sessionOperations, processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) })
  }

  init(
    repositoryDirectory: URL,
    worktree: DetectedWorktree,
    session: TmuxSessionName,
    sessionOperations: TmuxSessionOperations,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
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
    self.session = session
    self.sessionOperations = sessionOperations
    do {
      self.runner = try GitCloseWriteRunner(
        repositoryDirectory: repositoryDirectory, processRunner: processRunner,
        executableCandidates: executableCandidates, parentEnvironment: parentEnvironment,
        isExecutableFile: isExecutableFile)
      self.readRunner = try GitRunner(
        repositoryDirectory: repositoryDirectory, processRunner: processRunner,
        executableCandidates: executableCandidates, parentEnvironment: parentEnvironment,
        isExecutableFile: isExecutableFile)
    } catch {
      throw .git(error)
    }
  }

  /// - Throws: 計画が別の worktree のものだったとき。実行前に弾く —— 1 step でも撃ってからでは
  ///   巻き戻せない。
  public func execute(
    _ plan: WorktreeClosePlan
  ) async throws(WorktreeClosePlanMismatch) -> WorktreeCloseOutcome {
    guard plan.worktree == identity else {
      throw WorktreeClosePlanMismatch(plan: plan.worktree, executor: identity)
    }
    var completed: [WorktreeCloseStep] = []
    for (index, step) in plan.steps.enumerated() {
      guard let failure = await perform(step) else {
        completed.append(step)
        continue
      }
      return WorktreeCloseOutcome(
        completed: completed, failure: failure,
        skipped: Array(plan.steps[plan.steps.index(after: index)...]))
    }
    return WorktreeCloseOutcome(completed: completed, failure: nil, skipped: [])
  }

  private func perform(_ step: WorktreeCloseStep) async -> WorktreeCloseStepFailure? {
    switch step {
    case .terminateSession:
      await terminateSession(step)
    case .removeWorktree(let force):
      await removeWorktree(force: force, for: step)
    case .deleteBranch(let name):
      await write(GitCloseWriteCommand.deleteMergedBranch(name: name), for: step)
    }
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
  ///   `worktree` 行の文字列比較で行う。前者の出どころも同じ `worktree list --porcelain` なので
  ///   (`GitWorktreeDetector`)、git が返す表記どうしの比較になる。アプリ側で正規化しない
  ///   (`WorktreeIdentity` の doc コメントと同じ理由)。
  /// - Note: 解釈できなかった record があっても `dropped` の判定は曇らない。`GitWorktreeList` が
  ///   record を落とすのは `worktree ` 行そのものが無いときだけで、探しているパスを持つ record は
  ///   定義上そこに含まれない。
  private func registration() async -> WorktreeRegistrationAfterFailedRemoval {
    do {
      let result = try await readRunner.run(.worktreeList())
      let entries = GitWorktreeList.parse(output: result.stdout).entries
      return entries.contains { $0.path == worktreePath } ? .retained : .dropped
    } catch {
      return .unknown(error)
    }
  }

  /// `TmuxSessionOperations.kill` は「もう無かった」を成功へ丸めず、どちらを成功と見なすかを
  /// Close の選択肢へ委ねている。**Close の答えは、`sessionNotFound` と `serverNotRunning` を
  /// どちらも成功とする**である。選択肢2〜4 が求めているのは「この worktree の session が
  /// もう無いこと」であり、既に無い状態も server ごと落ちている状態もその結果を満たしている。
  /// 失敗にすると、session が先に消えた worktree では選択肢3・4 が二度と完了できず、
  /// 途中まで進んだ Close をやり直すこともできない —— 実行は巻き戻せないので、やり直しは
  /// 必要な操作である。
  ///
  /// tmux 3.4 実測: 稼働中 server で存在しない session は rc=1 `can't find session: <名前>`、
  /// server 停止後 (socket は残存) は rc=1 `no server running on <path>`、socket が一度も
  /// 作られていなければ rc=1 `error connecting to <path> (No such file or directory)`。
  ///
  /// これ以外は畳まない。通信できない server も分類できない失敗も「session が無い」証拠には
  /// ならず、agent プロセスが動いたまま worktree を消しにいくことになるためである。
  private func terminateSession(_ step: WorktreeCloseStep) async -> WorktreeCloseStepFailure? {
    do {
      try await sessionOperations.kill(session: session)
      return nil
    } catch .sessionNotFound, .serverNotRunning {
      return nil
    } catch {
      return WorktreeCloseStepFailure(step: step, reason: .tmux(error))
    }
  }

  private func write(
    _ command: GitCloseWriteCommand?, for step: WorktreeCloseStep
  ) async -> WorktreeCloseStepFailure? {
    guard let command else {
      return WorktreeCloseStepFailure(step: step, reason: .invalidArguments)
    }
    do {
      _ = try await runner.run(command)
      return nil
    } catch {
      return WorktreeCloseStepFailure(step: step, reason: .git(error))
    }
  }
}
