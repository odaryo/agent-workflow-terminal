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

public struct WorktreeCloseStepFailure: Error, Sendable, Equatable {
  public enum Reason: Sendable, Equatable {
    case tmux(TmuxSessionOperationError)
    case git(GitRunnerError)
    /// step の値から git の argv を組み立てられなかった。`WorktreeClosePlan` を作れている以上
    /// 起きるのは、`DetectedWorktree` から来た作業ツリーのパスや branch 名が
    /// `GitCloseWriteCommand` の受け付ける形でなかったときだけである。
    case invalidArguments
  }

  public let step: WorktreeCloseStep
  public let reason: Reason
}

/// どこまで進んだか。Close の後始末は**巻き戻せない**ので、「全部成功か例外か」の2値にしない
/// (設計書 §3.4)。
public struct WorktreeCloseOutcome: Sendable, Equatable {
  /// 成功した step。計画順。
  public let completed: [WorktreeCloseStep]
  /// 最初の失敗。`nil` なら全 step が成功した。
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
  private let worktreePath: String
  private let session: TmuxSessionName
  private let sessionOperations: TmuxSessionOperations
  private let runner: GitCloseWriteRunner

  public init(
    repositoryDirectory: URL,
    worktreePath: String,
    session: TmuxSessionName,
    sessionOperations: TmuxSessionOperations,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    try self.init(
      repositoryDirectory: repositoryDirectory, worktreePath: worktreePath, session: session,
      sessionOperations: sessionOperations, processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) })
  }

  init(
    repositoryDirectory: URL,
    worktreePath: String,
    session: TmuxSessionName,
    sessionOperations: TmuxSessionOperations,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
  ) throws(GitRunnerError) {
    // 消す worktree をそのまま渡す取り違えだけを弾く。`repositoryDirectory` が worktree の
    // **配下**にある場合は捕まえられず、そこは呼び出し側の責務として doc コメントに残す。
    guard repositoryDirectory.path != worktreePath else {
      throw .invalidRepositoryDirectory(repositoryDirectory)
    }
    self.worktreePath = worktreePath
    self.session = session
    self.sessionOperations = sessionOperations
    self.runner = try GitCloseWriteRunner(
      repositoryDirectory: repositoryDirectory, processRunner: processRunner,
      executableCandidates: executableCandidates, parentEnvironment: parentEnvironment,
      isExecutableFile: isExecutableFile)
  }

  public func execute(_ plan: WorktreeClosePlan) async -> WorktreeCloseOutcome {
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
      await write(GitCloseWriteCommand.removeWorktree(path: worktreePath, force: force), for: step)
    case .deleteBranch(let name):
      await write(GitCloseWriteCommand.deleteMergedBranch(name: name), for: step)
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
