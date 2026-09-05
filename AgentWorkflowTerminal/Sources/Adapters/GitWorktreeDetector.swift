import Foundation
import TerminalCore

/// entry 単位に還元できない失敗。これだけが `scan()` から throw される。
public enum GitWorktreeScanError: Error, Sendable, Equatable {
  case list(GitRunnerError)
  /// 1件でもあればスキャン全体を失敗させる。どの record が壊れたかは分かっても、それが
  /// どの worktree の record だったかは分からないので、entry 単位の失敗にできない。
  case malformedListOutput([GitWorktreeParseFailure])
  /// 検出した entry がこの Project のものかを判定する基準を引けなかった。
  case projectCommonDirectory(GitRunnerError)
  /// 基準の `rev-parse` が絶対パス1行を返さなかった。
  case unexpectedProjectCommonDirectoryOutput(output: String)
  /// entry 用の `GitRunner` を作れなかった。原因は git 実行ファイル側にあり、残りの entry も
  /// 同じ理由で失敗するので、entry 単位の失敗として集めても意味が無い。
  /// `GitWorktreeEntryFailure.Reason.gitDirectory` と分けているのは、そちらが
  /// 「git は動いたが失敗した」に限定され、作業ツリーの到達可能性で除外へ振り替わるためである。
  /// git を一度も起動できていない状況をその判定に混ぜると、git 実行ファイルの消失が
  /// 「作業ツリーが消えた」に化ける。
  case gitRunnerUnavailable(worktreePath: String, GitRunnerError)
}

/// entry 1件の失敗。`scan()` はこれを検出できた worktree と一緒に返す。
///
/// - Important: 呼び出し側が原因を再現できるよう、git の生の出力を丸めずに持つ。
///   失敗した worktree を UI でどう扱うかは Issue #137 の担当で、ここでは決めない。
public struct GitWorktreeEntryFailure: Sendable, Equatable {
  /// `worktree list` が返した作業ツリーのパス。安定 ID を引けていないので、これしか手掛かりが無い。
  public let worktreePath: String
  public let reason: Reason

  public enum Reason: Sendable, Equatable {
    /// 到達できる作業ツリーで安定 ID の `rev-parse` が失敗した。壊れているのが git ディレクトリ側
    /// とは限らない。分類は作業ツリーへ**到達できたかどうか**だけで決めており、git のメッセージは
    /// 見ていない (`describe`)。git 2.50.1 実測では、管理ディレクトリの `commondir` 欠落が
    /// `not a git repository: <管理ディレクトリ>`、`.git` ファイルの破損が `invalid gitfile format`、
    /// `.git` ファイルの消失が `not a git repository (or any of the parent directories): .git` で、
    /// いずれも exit 128。`worktree list` はこのどれにも `prunable` を付けない (網羅ではない)。
    case gitDirectory(GitRunnerError)
    /// `rev-parse` の出力が2行でなかった。パス自体に改行が含まれる場合もここへ来る。
    case unexpectedGitDirectoryOutput(output: String)
    /// 安定 ID にする1行目が絶対パスでなかった。
    case invalidGitDirectoryPath(gitDirectory: String)
    /// この Project のものかを判定する2行目が絶対パスでなかった。`invalidGitDirectoryPath` と
    /// 分けているのは、壊れているのが ID なのか判定基準なのかで呼び出し側の打ち手が変わるためである。
    case invalidCommonDirectoryPath(commonDirectory: String)
  }
}

/// - Important: `failures` を捨てて `detected` だけを `reconcileDetectedWorktrees` へ渡すと、
///   失敗した worktree は消失扱いになる (`GitWorktreeDetector` の契約を参照)。
public struct GitWorktreeScanResult: Sendable, Equatable {
  /// `worktree list` に現れた順。
  public let detected: [DetectedWorktree]
  /// 検出順。同じスキャンで `detected` と同時に立ち得る。
  public let failures: [GitWorktreeEntryFailure]
}

/// `git worktree list --porcelain -z` の結果から `DetectedWorktree` の一覧を作る (設計書 §3.2)。
///
/// - Important: **entry 1件の失敗でスキャン全体を落とさない。** git が entry 単位で失敗し得る形は
///   数え上げられない (git 2.50.1 実測: 0 バイトの `.git` ファイルは `prunable` が付かず、
///   ディレクトリとしては開けるのに `rev-parse` が exit 128 になる)。落とす設計だと、そのたびに
///   Project 全体の検出が止まる。代わりに検出できた worktree と entry 単位の失敗を
///   `GitWorktreeScanResult` で**両方**返し、throw するのは entry 単位に還元できない失敗
///   (`GitWorktreeScanError`) だけにする。
/// - Important: **entry ごとの失敗を黙って除外しない。** `reconcileDetectedWorktrees` は
///   渡された一覧を「そのスキャン時点の完全な一覧」として権威的に解釈し、載っていない安定 ID を
///   消失とみなす。1件でも黙って落として返すと、その worktree は消失扱いになり、次のスキャンで
///   復帰したときに**ユーザーが意図して Inactive にしていた worktree が自動 Active 化される**。
///   `detected` から外れてよいのは、作業ツリーがこの Project のものとして**存在しない**と
///   判定できた entry だけである (`isScannable` / `describe`)。その除外自体の代償は Issue #137。
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
  ///
  /// - Note: 同期 FS I/O を cooperative thread 上で行う。応答しないマウントで詰まり得るが、
  ///   この述語は git が既に同じパスへ `-C` して失敗した後にしか走らないので、そのマウントでは
  ///   git 側が先に詰まる。呼ぶ位置がここから動いたら、この前提も崩れる。
  private static let isReachableWorkingTree: @Sendable (String) -> Bool = { path in
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    return FileManager.default.isExecutableFile(atPath: path)
  }

  /// entry 1件の帰結。「不在として除外した」と「失敗した」を `nil` に潰すと、後者を黙って
  /// 落とすコードが書けてしまう。
  private enum EntryOutcome {
    case detected(DetectedWorktree)
    case absent
    case failed(GitWorktreeEntryFailure)

    static func failed(_ worktreePath: String, _ reason: GitWorktreeEntryFailure.Reason) -> Self {
      .failed(GitWorktreeEntryFailure(worktreePath: worktreePath, reason: reason))
    }
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

  /// - Returns: 不在として除外した entry はどちらの配列にも載せず、除外したこと自体も
  ///   呼び出し側へ伝えない (`isScannable` / `describe`)。
  public func scan() async throws(GitWorktreeScanError) -> GitWorktreeScanResult {
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
    // scannable な entry が0件でも撃つ。判定基準を引けない Project は「0件検出」ではなく
    // 「判定不能」であり、entry の顔ぶれ次第で成功したり失敗したりするほうが追いにくい。
    let commonDirectory = try await projectCommonDirectory()

    var detected: [DetectedWorktree] = []
    var failures: [GitWorktreeEntryFailure] = []
    for entry in parsed.entries where Self.isScannable(entry) {
      switch try await describe(entry, projectCommonDirectory: commonDirectory) {
      case .detected(let worktree): detected.append(worktree)
      case .absent: continue
      case .failed(let failure): failures.append(failure)
      }
    }
    return GitWorktreeScanResult(detected: detected, failures: failures)
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
  /// - Important: 除外の代償として、作業ツリーが一時的に失われた (ボリュームを外した等) worktree は
  ///   `reconcileDetectedWorktrees` から消失扱いになり、Active/Inactive を失う。戻ってきたときは
  ///   新規出現として自動 Active 化され、アプリからは新しく現れた worktree と区別できない。
  ///   ここを「失敗」にすると Project 全体の検出が止まるので不在として扱っており、この代償を
  ///   どう埋めるかは Issue #137 の担当。
  /// - Note: `locked` が付いた worktree には、作業ツリーが実在しなくても git は `prunable` を
  ///   付けない (git 2.50.1 実測)。可搬ボリューム上の worktree を lock するのは
  ///   `git worktree --help` が勧める運用なので異常系ではない。到達できない作業ツリーの除外は
  ///   ここではなく `describe` が行う。
  private static func isScannable(_ entry: GitWorktreeEntry) -> Bool {
    entry.prunableReason == nil && !entry.isBare
  }

  /// - Returns: `.absent` になるのは、この Project の作業ツリーとして存在しないと判定できた
  ///   次の2つだけ。どちらも `isScannable` の除外と同じ代償を負う (消失扱い → 復帰時に自動
  ///   Active 化。Issue #137)。それ以外の失敗は `.failed` で返し、黙って落とさない。
  ///   - 作業ツリーへ到達できない: `locked` で `prunable` が抑止された entry がここへ来る。
  ///     stderr の文言ではなく作業ツリーの到達可能性で判定するのは、git のメッセージが版と
  ///     locale で変わるためである。到達できる作業ツリーでの失敗は
  ///     `GitWorktreeEntryFailure.Reason.gitDirectory` に回す。壊れているのが git ディレクトリ
  ///     側か作業ツリー側かは、そこでも区別していない。
  ///   - common dir がこの Project のものでない: 登録済み worktree のディレクトリが別の
  ///     repository に置き換わると、git は `prunable` を付けず、`rev-parse` も exit 0 で
  ///     **その別 repository の** git ディレクトリを返す (git 2.50.1 実測)。そのまま通すと
  ///     Project Root が2件になり、安定 ID が別 Project の `.git` を指して tmux session 名まで
  ///     衝突し得る。この Project の worktree ではないので、失敗ではなく不在として扱う。
  private func describe(
    _ entry: GitWorktreeEntry,
    projectCommonDirectory: WorktreeIdentity
  ) async throws(GitWorktreeScanError) -> EntryOutcome {
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
      guard isWorktreeReachable(entry.path) else { return .absent }
      return .failed(entry.path, .gitDirectory(error))
    }

    let paths = stdout.split(separator: "\n")
    guard paths.count == 2 else {
      return .failed(entry.path, .unexpectedGitDirectoryOutput(output: stdout))
    }
    guard let identity = WorktreeIdentity(rawValue: String(paths[0])) else {
      return .failed(entry.path, .invalidGitDirectoryPath(gitDirectory: String(paths[0])))
    }
    // common dir は Project Root の安定 ID そのものなので同じ型で持つ (設計書 §3.5)。比較を
    // `WorktreeIdentity` に委ねることで、正準等価な別表記を別 ID とする規則がここへ二重化しない。
    guard let commonDirectory = WorktreeIdentity(rawValue: String(paths[1])) else {
      return .failed(entry.path, .invalidCommonDirectoryPath(commonDirectory: String(paths[1])))
    }
    guard commonDirectory == projectCommonDirectory else { return .absent }

    return .detected(
      DetectedWorktree(
        identity: identity,
        worktreePath: entry.path,
        branch: entry.branch.map(Self.shortBranchName),
        isProjectRoot: identity == commonDirectory
      ))
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
