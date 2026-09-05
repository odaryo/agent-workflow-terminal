import Foundation
import TerminalCore

public enum GitWorktreeScanError: Error, Sendable, Equatable {
  case list(GitRunnerError)
  /// 1件でもあればスキャン全体を失敗させる。
  case malformedListOutput([GitWorktreeParseFailure])
  /// 検出した entry がこの Project のものかを判定する基準を引けなかった。
  case projectCommonDirectory(GitRunnerError)
  /// 基準の `rev-parse` が絶対パス1行を返さなかった。
  case unexpectedProjectCommonDirectoryOutput(output: String)
  /// entry 用の `GitRunner` を作れなかった。`.gitDirectory` と分けているのは、そちらが
  /// 「git は動いたが失敗した」に限定され、作業ツリーの到達可能性で除外へ振り替わるためである。
  /// git を一度も起動できていない状況をその判定に混ぜると、git 実行ファイルの消失が
  /// 「作業ツリーが消えた」に化ける。
  case gitRunnerUnavailable(worktreePath: String, GitRunnerError)
  /// 到達できる作業ツリーで安定 ID の `rev-parse` が失敗した。git 2.50.1 実測では、管理
  /// ディレクトリの `commondir` 欠落が `not a git repository: <管理ディレクトリ>`、`.git`
  /// ファイルの破損が `invalid gitfile format` で、どちらも exit 128。`worktree list` は
  /// この2つに `prunable` を付けない。
  case gitDirectory(worktreePath: String, GitRunnerError)
  /// `rev-parse` の出力が2行でなかった。パス自体に改行が含まれる場合もここへ来る。
  case unexpectedGitDirectoryOutput(worktreePath: String, output: String)
  case invalidGitDirectoryPath(worktreePath: String, gitDirectory: String)
}

/// `git worktree list --porcelain -z` の結果から `DetectedWorktree` の一覧を作る (設計書 §3.2)。
///
/// - Important: **entry ごとの失敗で部分的な結果を返さない。** `reconcileDetectedWorktrees` は
///   渡された一覧を「そのスキャン時点の完全な一覧」として権威的に解釈し、載っていない安定 ID を
///   消失とみなす。1件でも取りこぼして返すと、その worktree は消失扱いになり、次のスキャンで
///   復帰したときに**ユーザーが意図して Inactive にしていた worktree が自動 Active 化される**。
///   例外は、失敗させると**スキャン全体が恒久的に止まる**種類の entry だけで、それらは
///   `prunable` と同じ除外へ回す (`isScannable` / `describe`)。1件の事故で Project 全体の検出を
///   止めるほうが害が大きいという判断であり、除外そのものの代償は Issue #137 で扱う。
/// - Important: 安定 ID は必ず git に問い合わせる。`git rev-parse --path-format=absolute` の
///   出力は symlink 解決とディスク上の大小文字への矯正を経た正規形であり、`WorktreeIdentity` が
///   正規化しない設計はこの出力をそのまま渡すことで成立している。作業ツリーのパスと
///   `worktrees/<name>` を文字列連結して組み立てると、その前提が消える。git は管理ディレクトリ名を
///   サニタイズするので (git 2.50.1 実測: `wt2 with space` → `worktrees/wt2-with-space`)、
///   連結した文字列はそもそも実際の安定 ID と一致しない。
public struct GitWorktreeDetector: Sendable {
  /// `--path-format=absolute` は**それ以降のオプションにだけ効く**ため、位置に意味がある
  /// (git 2.31 以降。サポート下限は 2.39 なので使える)。1回の実行で管理ディレクトリと
  /// common dir の2行が得られ、2行が等しいかどうかが main worktree か否かの判定になる
  /// (git 2.50.1 実測)。`worktree list` の並び順に依存せずに済む。
  private static let gitDirectoryArguments = [
    "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
  ]

  /// linked worktree から引いても main worktree から引いても同じ値が返る (git 2.50.1 実測) ため、
  /// Project ディレクトリがどの worktree にあっても同じ基準になる。
  private static let commonDirectoryArguments = [
    "rev-parse", "--path-format=absolute", "--git-common-dir",
  ]

  private static let branchRefPrefix = "refs/heads/"

  /// `git -C <path>` は chdir するので、ディレクトリとして開けるかどうかがそのまま到達可能性に
  /// なる。git 2.50.1 実測では、パスが消えていれば `No such file or directory`、パスがファイル
  /// なら `Not a directory`、探索権限が無ければ `Permission denied` で、いずれも exit 128。
  private static let isReachableWorkingTree: @Sendable (String) -> Bool = { path in
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    return FileManager.default.isExecutableFile(atPath: path)
  }

  private let projectRunner: GitRunner
  /// worktree ごとに `-C <作業ツリー>` を変えて git を実行するため、`GitRunner` は entry ごとに作る。
  private let makeRunner: @Sendable (URL) throws(GitRunnerError) -> GitRunner
  private let isWorktreeReachable: @Sendable (String) -> Bool

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
    self.isWorktreeReachable = Self.isReachableWorkingTree
  }

  init(
    projectRunner: GitRunner,
    makeRunner: @escaping @Sendable (URL) throws(GitRunnerError) -> GitRunner,
    isWorktreeReachable: @escaping @Sendable (String) -> Bool = Self.isReachableWorkingTree
  ) {
    self.projectRunner = projectRunner
    self.makeRunner = makeRunner
    self.isWorktreeReachable = isWorktreeReachable
  }

  /// - Returns: `worktree list` に現れた順。除外した entry は載せず、除外したこと自体も
  ///   呼び出し側へ伝えない (`isScannable` / `describe`)。
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
    let commonDirectory = try await projectCommonDirectory()

    var detected: [DetectedWorktree] = []
    for entry in parsed.entries where Self.isScannable(entry) {
      guard let described = try await describe(entry, projectCommonDirectory: commonDirectory)
      else { continue }
      detected.append(described)
    }
    return detected
  }

  /// 除外した entry は返り値に載せず、除外したこと自体も呼び出し側へ伝えない。
  ///
  /// - `prunable`: 作業ツリーが実在しないので、タブも tmux session も持てず、そもそも
  ///   安定 ID を引けない (`rev-parse` が exit 128。git 2.50.1 実測)。§3.2 には
  ///   「検出したが使えない worktree」という状態が無く、ここで返すと設計書に無い状態を
  ///   発明することになる。`git worktree prune` は書き込み操作であり §17.2 で Agent へ委譲済み。
  /// - bare: 作業ツリーが無い。`rev-parse` 自体は exit 0 で使える安定 ID を返すが (git 2.50.1
  ///   実測: `--git-dir` も `--git-common-dir` も bare ディレクトリ自身)、`worktreePath` が
  ///   指すのは git ディレクトリであって checkout ではないため、タブの cwd にも tmux session の
  ///   作業ディレクトリにも使えない。結果として bare repository の Project は
  ///   `projectRoot == nil` になる。その可否は Issue #138 で決める。
  ///
  /// - Note: `locked` が付いた worktree には、作業ツリーが実在しなくても git は `prunable` を
  ///   付けない (git 2.50.1 実測)。可搬ボリューム上の worktree を lock するのは
  ///   `git worktree --help` が勧める運用なので異常系ではない。到達できない作業ツリーの除外は
  ///   ここではなく `describe` が行う。
  private static func isScannable(_ entry: GitWorktreeEntry) -> Bool {
    entry.prunableReason == nil && !entry.isBare
  }

  /// - Returns: 除外する entry では `nil`。
  ///   - 作業ツリーへ到達できない: `locked` で `prunable` が抑止された entry がここへ来る。
  ///     失敗させると、lock を外すかディレクトリを戻すまで Project Root を含む**全 worktree の
  ///     検出が止まる**。stderr の文言ではなく作業ツリーの到達可能性で判定するのは、git の
  ///     メッセージが版と locale で変わるためである。到達できる作業ツリーでの失敗は git
  ///     ディレクトリ側の破損なので、そちらは従来どおり失敗させる (`.gitDirectory`)。
  ///   - common dir がこの Project のものでない: 登録済み worktree のディレクトリが別の
  ///     repository に置き換わると、git は `prunable` を付けず、`rev-parse` も exit 0 で
  ///     **その別 repository の** git ディレクトリを返す (git 2.50.1 実測)。そのまま通すと
  ///     Project Root が2件になり、安定 ID が別 Project の `.git` を指して tmux session 名まで
  ///     衝突し得る。失敗させずに除外するのは、上と同じく1件の事故で Project 全体の検出を
  ///     恒久的に止めないためである。
  private func describe(
    _ entry: GitWorktreeEntry,
    projectCommonDirectory: WorktreeIdentity
  ) async throws(GitWorktreeScanError) -> DetectedWorktree? {
    let runner: GitRunner
    do {
      runner = try makeRunner(URL(fileURLWithPath: entry.path))
    } catch {
      throw .gitRunnerUnavailable(worktreePath: entry.path, error)
    }

    let stdout: String
    do {
      // 読み取り専用の subcommand をモジュール内で組み立てる。`GitReadCommand` の
      // initializer が internal なのは、書き込み subcommand をモジュール外から
      // 注入させないためである (§17.2)。
      stdout = try await runner.run(GitReadCommand(arguments: Self.gitDirectoryArguments)).stdout
    } catch {
      guard isWorktreeReachable(entry.path) else { return nil }
      throw .gitDirectory(worktreePath: entry.path, error)
    }

    let paths = stdout.split(separator: "\n")
    guard paths.count == 2 else {
      throw .unexpectedGitDirectoryOutput(worktreePath: entry.path, output: stdout)
    }
    guard let identity = WorktreeIdentity(rawValue: String(paths[0])) else {
      throw .invalidGitDirectoryPath(worktreePath: entry.path, gitDirectory: String(paths[0]))
    }
    // common dir は Project Root の安定 ID そのものなので同じ型で持つ (設計書 §3.5)。比較を
    // `WorktreeIdentity` に委ねることで、正準等価な別表記を別 ID とする規則がここへ二重化しない。
    guard let commonDirectory = WorktreeIdentity(rawValue: String(paths[1])) else {
      throw .invalidGitDirectoryPath(worktreePath: entry.path, gitDirectory: String(paths[1]))
    }
    guard commonDirectory == projectCommonDirectory else { return nil }

    return DetectedWorktree(
      identity: identity,
      worktreePath: entry.path,
      branch: entry.branch.map(Self.shortBranchName),
      isProjectRoot: identity == commonDirectory
    )
  }

  private func projectCommonDirectory() async throws(GitWorktreeScanError) -> WorktreeIdentity {
    let stdout: String
    do {
      stdout = try await projectRunner.run(
        GitReadCommand(arguments: Self.commonDirectoryArguments)
      ).stdout
    } catch {
      throw .projectCommonDirectory(error)
    }

    let lines = stdout.split(separator: "\n")
    guard lines.count == 1, let identity = WorktreeIdentity(rawValue: String(lines[0])) else {
      throw .unexpectedProjectCommonDirectoryOutput(output: stdout)
    }
    return identity
  }

  /// `refs/heads/` が付かない値は加工せずに返す。branch 名は `feat/a` のように `/` を含み得るので、
  /// 最後の要素を取る短縮はできない。
  private static func shortBranchName(_ reference: String) -> String {
    guard reference.hasPrefix(branchRefPrefix) else { return reference }
    return String(reference.dropFirst(branchRefPrefix.count))
  }
}
