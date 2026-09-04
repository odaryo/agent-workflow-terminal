import Foundation
import TerminalCore

public enum GitWorktreeScanError: Error, Sendable, Equatable {
  case list(GitRunnerError)
  /// `GitWorktreeList` が壊れた record を返した。1件でもあればスキャン全体を失敗させる。
  case malformedListOutput([GitWorktreeParseFailure])
  /// 安定 ID を問い合わせる `rev-parse` の失敗。作業ツリーが消えていれば exit 128 と
  /// `fatal: cannot change to '<path>': No such file or directory` になる (git 2.50.1 実測)。
  case gitDirectory(worktreePath: String, GitRunnerError)
  /// `rev-parse` の出力が2行でなかった。パス自体に改行が含まれる場合もここへ来る。
  case unexpectedGitDirectoryOutput(worktreePath: String, output: String)
  case invalidGitDirectoryPath(worktreePath: String, gitDirectory: String)
}

/// `git worktree list --porcelain -z` の結果から `DetectedWorktree` の一覧を作る (設計書 §3.2)。
///
/// - Important: **部分的な結果を返さない。** `reconcileDetectedWorktrees` は渡された一覧を
///   「そのスキャン時点の完全な一覧」として権威的に解釈し、載っていない安定 ID を消失とみなす。
///   1件でも取りこぼして返すと、その worktree は消失扱いになり、次のスキャンで復帰したときに
///   **ユーザーが意図して Inactive にしていた worktree が自動 Active 化される**。したがって
///   entry ごとの失敗もスキャン全体の失敗として投げる。契約を守る強制点はこの型にある。
/// - Important: 安定 ID は必ず git に問い合わせる。`git rev-parse --path-format=absolute` の
///   出力は symlink 解決とディスク上の大小文字への矯正を経た正規形であり、`WorktreeIdentity` が
///   正規化しない設計はこの出力をそのまま渡すことで成立している。作業ツリーのパスと
///   `worktrees/<name>` を文字列連結して組み立てると、その前提が消える。
public struct GitWorktreeDetector: Sendable {
  /// `--path-format=absolute` は**それ以降のオプションにだけ効く**ため、位置に意味がある
  /// (git 2.31 以降。サポート下限は 2.39 なので使える)。1回の実行で管理ディレクトリと
  /// common dir の2行が得られ、2行が等しいかどうかが main worktree か否かの判定になる
  /// (git 2.50.1 実測)。`worktree list` の並び順に依存せずに済む。
  private static let gitDirectoryArguments = [
    "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
  ]

  private static let branchRefPrefix = "refs/heads/"

  private let projectRunner: GitRunner
  /// worktree ごとに `-C <作業ツリー>` を変えて git を実行するため、`GitRunner` は entry ごとに作る。
  private let makeRunner: @Sendable (URL) throws(GitRunnerError) -> GitRunner

  public init(
    projectDirectory: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    self.projectRunner = try GitRunner(
      repositoryDirectory: projectDirectory,
      processRunner: processRunner,
      executableCandidates: executableCandidates
    )
    self.makeRunner = { directory throws(GitRunnerError) in
      try GitRunner(
        repositoryDirectory: directory,
        processRunner: processRunner,
        executableCandidates: executableCandidates
      )
    }
  }

  init(
    projectRunner: GitRunner,
    makeRunner: @escaping @Sendable (URL) throws(GitRunnerError) -> GitRunner
  ) {
    self.projectRunner = projectRunner
    self.makeRunner = makeRunner
  }

  /// - Returns: `worktree list` に現れた順。`prunable` と bare の entry は含まない (`isScannable`)。
  public func scan() async throws(GitWorktreeScanError) -> [DetectedWorktree] {
    let output: String
    do {
      output = try await projectRunner.run(.worktreeList()).stdout
    } catch {
      throw .list(error)
    }

    let parsed = GitWorktreeList.parse(output: output)
    guard parsed.failures.isEmpty else {
      throw .malformedListOutput(parsed.failures)
    }

    var detected: [DetectedWorktree] = []
    for entry in parsed.entries where Self.isScannable(entry) {
      detected.append(try await describe(entry))
    }
    return detected
  }

  /// 除外した entry は返り値に載せず、除外したこと自体も呼び出し側へ伝えない。
  ///
  /// - `prunable`: 作業ツリーが実在しないので、タブも tmux session も持てず、そもそも
  ///   安定 ID を引けない (`rev-parse` が exit 128。git 2.50.1 実測)。§3.2 には
  ///   「検出したが使えない worktree」という状態が無く、ここで返すと設計書に無い状態を
  ///   発明することになる。`git worktree prune` は書き込み操作であり §17.2 で Agent へ委譲済み。
  /// - bare: 作業ツリーが無い。`git -C <bare> status` は
  ///   `fatal: this operation must be run in a work tree` になり (実測)、`worktreePath` は
  ///   git ディレクトリ自身を指すため、そこを作業ディレクトリにした session は checkout の
  ///   外で動く。結果として bare repository の Project は `projectRoot == nil` になる。
  ///
  /// - Note: 除外の帰結として、作業ツリーが一時的に失われた (ボリュームを外した等) worktree は
  ///   `reconcileDetectedWorktrees` から消失扱いになり、Active/Inactive を失う。戻ってきたときは
  ///   新規出現として自動 Active 化される。アプリからは新しく現れた worktree と区別できない。
  private static func isScannable(_ entry: GitWorktreeEntry) -> Bool {
    entry.prunableReason == nil && !entry.isBare
  }

  private func describe(
    _ entry: GitWorktreeEntry
  ) async throws(GitWorktreeScanError) -> DetectedWorktree {
    let stdout: String
    do {
      let runner = try makeRunner(URL(fileURLWithPath: entry.path))
      // 読み取り専用の subcommand をモジュール内で組み立てる。`GitReadCommand` の
      // initializer が internal なのは、書き込み subcommand をモジュール外から
      // 注入させないためである (§17.2)。
      stdout = try await runner.run(GitReadCommand(arguments: Self.gitDirectoryArguments)).stdout
    } catch {
      throw .gitDirectory(worktreePath: entry.path, error)
    }

    let paths = stdout.split(separator: "\n")
    guard paths.count == 2 else {
      throw .unexpectedGitDirectoryOutput(worktreePath: entry.path, output: stdout)
    }
    guard let identity = WorktreeIdentity(rawValue: String(paths[0])) else {
      throw .invalidGitDirectoryPath(worktreePath: entry.path, gitDirectory: String(paths[0]))
    }

    return DetectedWorktree(
      identity: identity,
      worktreePath: entry.path,
      branch: entry.branch.map(Self.shortBranchName),
      // 安定 ID の同一性と同じくバイト列で比べる (`WorktreeIdentity` 参照)。
      isProjectRoot: paths[0].utf8.elementsEqual(paths[1].utf8)
    )
  }

  /// `refs/heads/` が付かない値は加工せずに返す。branch 名は `feat/a` のように `/` を含み得るので、
  /// 最後の要素を取る短縮はできない。
  private static func shortBranchName(_ reference: String) -> String {
    guard reference.hasPrefix(branchRefPrefix) else { return reference }
    return String(reference.dropFirst(branchRefPrefix.count))
  }
}
