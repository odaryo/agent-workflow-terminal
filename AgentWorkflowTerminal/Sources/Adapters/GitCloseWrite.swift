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
/// 2. 作れるのは `worktree remove` と `branch -D` の2つだけ。private initializer により、
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

  /// **`-d` ではなく `-D` (`--delete --force`) で消す** (§3.4 確定 2026-10-08、Issue #359)。
  /// `-d` は squash merge をマージ済みと認めず、upstream が削除されて `fetch --prune` された後
  /// —— PR のマージ後に Close する最も普通の状況 —— は削除を拒否する (git 2.50.1 実測: rc=1 /
  /// `error: the branch 'topic' is not fully merged`、同じ branch に `-D` は rc=0)。判定と実行で
  /// 「マージ済み」の定義が食い違ったままでは選択肢4が squash merge 運用で必ず失敗するので、
  /// アプリ自身の ancestor／patch 同一性の判定 (`BranchMergeStatus.merged`) を根拠にする。
  ///
  /// その代わり **git 側に未merge を拒否する防波堤は無い**。`-D` を撃てるのは
  /// `planWorktreeClose` が「マージ済み」と判定して `.deleteBranch` を載せた計画だけで、その経路を
  /// 型で閉じているのは3つ —— この型の private initializer、`WorktreeClosePlan` の internal
  /// initializer、`WorktreeCloseExecutor.execute` が計画しか受け取らないこと —— である。判定の後に
  /// branch へ積まれた commit を巻き込まないよう、実行層は先端が判定時
  /// (`WorktreeCloseStep.deleteBranch` の `tip`) のままかを2回確かめる —— session を終了する前と、
  /// これを撃つ直前である。
  ///
  /// - Parameter name: 短縮 local branch 名。`refs/` 始まりを弾くのは、`branch -D` が完全修飾した
  ///   形も `refs/` 始まりの値も rc=1 の `not found` にするためで (git 2.50.1 実測)、argv の形の
  ///   検証である。同じ前置を見る Issue #142 の暫定 guard (`isBranchDeletionAvailable`) とは
  ///   目的が別で、そちらは選択肢4を提供するかどうかを決める。
  /// - Returns: 短縮 local branch 名でなければ `nil`。
  static func deleteMergedBranch(name: String) -> Self? {
    guard !name.isEmpty, !name.hasPrefix("refs/") else { return nil }
    return Self(arguments: ["branch", "--delete", "--force", "--", name])
  }
}

/// Close の後始末の git 書き込みだけを撃つ。
///
/// - Important: 実行ファイルの解決と子プロセスへ渡す環境は `GitRunner` と同じ規則で組み立てる。
///   同じ規則が2か所にあるのは、`GitRunner` 側の該当メンバが `private` で、別ファイルからは
///   参照できないためである。**片方だけを変えると git の起動条件が読み取りと書き込みで割れる。**
///   例外として replace / grafts の無視は読み取り側の Close 安全確認だけに付ける。書き込み前の tip 照合は ref の OID を引くため影響を受けない。
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
