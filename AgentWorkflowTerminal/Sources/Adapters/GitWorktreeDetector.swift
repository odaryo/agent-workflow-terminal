import Darwin
import Foundation
import TerminalCore

/// entry 単位に還元できない失敗。これだけが `scan()` から throw される。
public enum GitWorktreeScanError: Error, Sendable, Equatable {
  /// - Important: `worktree list` 自体が entry 1件の事故で全滅する。git 2.50.1 実測では、ある
  ///   worktree の `locked` を `chmod 000` にすると
  ///   `fatal: failed to read '.git/worktrees/wt2/locked': Permission denied` で exit 128 になり、
  ///   その worktree より前の record を完全な形で吐いてから死ぬ (壊れた worktree 自身の record は
  ///   終端の `\0` を欠いた途中まで、それより後の worktree は1件も現れない)。部分 stdout は
  ///   `GitRunnerError.commandFailed` が保持しているが、それを信用して検出を続けるかは
  ///   Issue #140 の担当で、現状はここへ来て Project 全体の検出が止まる。
  case list(GitRunnerError)
  /// 1件でもあればスキャン全体を失敗させる。どの record が壊れたかは分かっても、それが
  /// どの worktree の record だったかは分からないので、entry 単位の失敗にできない。
  case malformedListOutput([GitWorktreeParseFailure])
  /// 検出した entry がこの Project のものかを判定する基準を引けなかった。
  case projectCommonDirectory(GitRunnerError)
  /// 基準の `rev-parse` が絶対パス1行を返さなかった。
  case unexpectedProjectCommonDirectoryOutput(output: String)
  /// entry 用の `GitRunner` を作れなかった。実際に起きるのは git 実行ファイルを見つけられない
  /// 場合で、残りの entry も同じ理由で失敗するため entry 単位の失敗として集めても意味が無い。
  /// `GitRunner.init` は entry のパスに依存する `invalidRepositoryDirectory` も throw するが、
  /// `worktree list --porcelain` は `worktree.useRelativePaths=true` を設定しても作業ツリーの
  /// **絶対**パスしか吐かず (git 2.50.1 実測: 相対になるのは `.git` ファイルの中身だけで
  /// `gitdir: ../main/.git/worktrees/wt1`)、絶対パスから作った `URL` は `baseURL` を持たないので
  /// (macOS 26.5 実測: 相対パスだと cwd が `baseURL` に入って弾かれる) 現状は到達しない。
  /// `GitWorktreeEntryFailure.Reason.gitDirectory` と分けているのは、そちらが
  /// 「git は動いた」に限定され、作業ツリーの到達可能性で除外へ振り替わるためである。
  /// git を一度も起動できていない状況をその判定に混ぜると、git 実行ファイルの消失が
  /// 「作業ツリーが消えた」に化ける。
  case gitRunnerUnavailable(worktreePath: String, GitRunnerError)
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
///   検出できない entry は `failures` に残す。ただし bare、到達不能と確認できない
///   `prunable`、common dir が別 Project の entry は対象外として除外する (`isScannable` /
///   `describe`)。`prunable` だけでは不在の証拠にならない (Issue #496)。除外自体の代償は Issue #137。
/// - Important: 到達可能な作業ツリーの安定 ID は git に問い合わせる。`git rev-parse --path-format=absolute` の
///   出力は symlink 解決とディスク上の大小文字への矯正を経た正規形であり、`WorktreeIdentity` が
///   正規化しない設計はこの出力をそのまま渡すことで成立している。作業ツリーのパスと
///   `worktrees/<name>` を文字列連結して組み立てると、その前提が消える。git は管理ディレクトリ名を
///   サニタイズするので (git 2.50.1 実測: `wt2 with space` → `worktrees/wt2-with-space`)、
///   連結した文字列はそもそも実際の安定 ID と一致しない。到達不能な場合も作業ツリーパスから
///   組み立てず、common dir 配下の管理ディレクトリと照合する (`administrativeDirectory`)。
public struct GitWorktreeDetector: Sendable {
  /// `--path-format=absolute` は**それ以降のオプションにだけ効く**ため、位置に意味がある
  /// (git 2.31 以降。サポート下限は 2.39 なので使える)。1回の実行で管理ディレクトリと
  /// common dir の2行が得られ、main worktree では2行が等しくなる (git 2.50.1 実測)。ただし
  /// `.git` を失った linked worktree からは祖先へ遡って等しくなり得るので、等しいことだけでは
  /// main worktree と判定しない (`describe`、Issue #502)。
  private static let gitDirectoryArguments = [
    "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
  ]

  /// main worktree でない entry にだけ使う。main に足さない理由は
  /// `GitWorktreeEntryFailure.Reason.resolvedToAncestorRepository`。
  private static let linkedWorktreeArguments =
    gitDirectoryArguments + ["--is-bare-repository", "--show-prefix"]

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
  /// - Note: 同期 FS I/O を cooperative thread 上で行い、**打ち切る手段が無い**。
  ///   `fileExists` / `isExecutableFile` は timeout も cancellation も取らない同期 API で
  ///   (macOS 26.5 SDK の `NSFileManager.h`)、下の `stat(2)` / `access(2)` にも timeout は無い。
  ///   別スレッドへ逃がして時間で見切ることはできるが、ブロックしたスレッド自体は殺せないので
  ///   漏れるだけである。SIGTERM / SIGKILL で殺せる子については git 側も有界に戻る
  ///   (実測: SIGTERM を無視する直接の子を 80 ミリ秒 timeout で撃ち、0.201 秒で停止・回収)。
  ///   応答しないマウント上の `chdir` では SIGKILL が syscall の復帰まで保留され得るため、git 側も
  ///   有界に戻るかは未確認である。Swift の同期ブロックはキャンセルもプリエンプトもされないため
  ///   (実測: 10 コアの機で 0.3 秒ブロックする `Task.detached` を10本作ると10本は並列に走るが、
  ///   11本目は 0.308 秒まで走れない。トップレベルの `Task` は MainActor 隔離を継承して直列になり、
  ///   10本で 3.110 秒かかった)、応答しないマウントでは git が回復しても述語だけが無期限に残る。
  ///   そのため非 prunable の entry では **git が exit code を返した失敗にだけ**撃つ。
  ///   prunable の事前判定は例外である。`.git` を消しただけの入れるディレクトリを通すと、
  ///   `rev-parse` が祖先へ遡り、bare 配置では偽の Project Root を検出する (Issue #496 の
  ///   レビュアー計測)。入れない場合は `rev-parse` が必ず失敗するため、事前判定後は直接
  ///   admin 側で照合する。この事前判定には同期 FS I/O が詰まる窓が残る。
  ///   非 prunable で git が終了しなかった場合 (timeout 等) は述語を撃たない。ただし
  ///   `ProcessRunner` は deadline 後も子の終了通知を待つため、子が死ななければ `GitRunner.run` の
  ///   `await` 自体が解けず、応答しないマウントで git 自体が戻らない窓は別に残る。
  ///   `commandFailed` を返しつつ後続の `stat` は詰まるマウントは残るが、それは実測できておらず、
  ///   打ち切れない以上どのみち別の設計判断 (どの時点で不在とみなすか) が要るので今は許容する。
  private static let isReachableWorkingTree: @Sendable (String) -> Bool = { path in
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    return FileManager.default.isExecutableFile(atPath: path)
  }

  /// entry 1件の帰結。「対象外として除外した」と「失敗した」を `nil` に潰すと、後者を黙って
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
  private let findAdministrativeDirectory: @Sendable (String, WorktreeIdentity) -> WorktreeIdentity?
  /// `nil` は `GitRunner` の既定 (30 秒)。テストが実プロセスの timeout を現実的な時間で起こすため
  /// だけの注入口で、製品の経路はここを触らない。
  private let entryTimeout: Duration?

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
    self.findAdministrativeDirectory = Self.administrativeDirectory
    self.entryTimeout = nil
  }

  init(
    projectRunner: GitRunner,
    makeRunner: @escaping @Sendable (URL) throws(GitRunnerError) -> GitRunner,
    isWorktreeReachable: @escaping @Sendable (String) -> Bool = Self.isReachableWorkingTree,
    findAdministrativeDirectory:
      @escaping @Sendable (String, WorktreeIdentity) -> WorktreeIdentity? =
      Self.administrativeDirectory,
    entryTimeout: Duration? = nil
  ) {
    self.projectRunner = projectRunner
    self.makeRunner = makeRunner
    self.isWorktreeReachable = isWorktreeReachable
    self.findAdministrativeDirectory = findAdministrativeDirectory
    self.entryTimeout = entryTimeout
  }

  /// - Returns: 対象外として除外した entry はどちらの配列にも載せず、除外したこと自体も
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
    // main worktree は `worktree list` の最初の entry (git-worktree(1))。bare の entry も
    // main として最初に現れるので、scannable で絞る前の順序で決める。
    for (index, entry) in parsed.entries.enumerated() where isScannable(entry) {
      switch try await describe(
        entry, isMainWorktree: index == 0, projectCommonDirectory: commonDirectory)
      {
      case .detected(let worktree): detected.append(worktree)
      case .absent: continue
      case .failed(let failure): failures.append(failure)
      }
    }
    return Self.resolveSharedIdentities(
      detected: detected, failures: failures, commonDirectory: commonDirectory,
      findAdministrativeDirectory: findAdministrativeDirectory)
  }

  /// 除外した entry は返り値に載せず、除外したこと自体も呼び出し側へ伝えない。
  ///
  /// - `prunable`: Issue #496 の git 2.50.1 実測では、unlocked の作業ツリーを `chmod 000` にすると
  ///   `prunable gitdir file points to non-existent location` が付き、locked では付かない。
  ///   `.git` ファイルの消失でも同じ理由が付くため、`prunable` は作業ツリーの不在の証拠に
  ///   ならない。一方、`.git` を消しただけの入れるディレクトリで `rev-parse` を走らせると
  ///   祖先へ遡り、bare 配置では偽の Project Root になる (同 Issue のレビュアー計測)。
  ///   入れない場合は必ず失敗するため、通した entry は git を走らせず admin 側で照合する。
  ///   symlink のリンク先まで対象を広げないため、存在と種別の確認には `lstat` を使う。
  ///   `git worktree prune` は書き込み操作であり設計書 §17.2 で Agent へ委譲済み。
  /// - Important: prunable の entry を落とすのは、`GitWorktreeScanResult` の「黙って落とすと
  ///   Inactive が自動 Active 化される」の例外として受け入れたものである (Issue #496)。
  ///   `.git` を消しただけの**入れる**ディレクトリも、作業ツリーが残っていても消失扱いで落とす。
  ///   通すのは、入れないディレクトリと、`lstat` が `EACCES` を返した (祖先の探索権限が無い)
  ///   entry だけである。`ENOENT` 以外を一律に通すと、祖先が通常ファイルに置き換わった
  ///   `ENOTDIR` まで到達不能として残る。未計測の仮説: TCC やサンドボックスで `lstat` が
  ///   `EPERM` を返すと、実在する worktree が消失扱いになる。
  /// - bare: 作業ツリーが無い。`rev-parse` 自体は exit 0 で使える安定 ID を返すが (git 2.50.1
  ///   実測: `--git-dir` も `--git-common-dir` も bare ディレクトリ自身)、`worktreePath` が
  ///   指すのは git ディレクトリであって checkout ではないため、タブの cwd にも tmux session の
  ///   作業ディレクトリにも使えない。結果として bare repository の Project は
  ///   `projectRoot == nil` になる。これは設計書 §2.3 で正常系として確定済みで、
  ///   Project Root タブを持たない Project を上位レイヤが扱う。
  /// - Note: `locked` が付いた worktree には、作業ツリーが実在しなくても git は `prunable` を
  ///   付けない (git 2.50.1 実測)。可搬ボリューム上の worktree を lock するのは
  ///   `git worktree --help` が勧める運用なので異常系ではない。到達できない作業ツリーは
  ///   `describe` が Project Root 側の admin ディレクトリと照合して検出結果へ残す。
  private func isScannable(_ entry: GitWorktreeEntry) -> Bool {
    guard !entry.isBare else { return false }
    guard entry.prunableReason != nil else { return true }
    var info = stat()
    guard lstat(entry.path, &info) == 0 else { return errno == EACCES }
    return info.st_mode & S_IFMT == S_IFDIR && !isWorktreeReachable(entry.path)
  }

  /// - Returns: `.absent` になるのは、common dir がこの Project のものでない entry (下記の2つ目)
  ///   だけ。到達できない作業ツリー (1つ目) は `isReachable == false` の `.detected` になる。
  ///   それ以外の失敗は `.failed` で返し、黙って落とさない。
  ///   - 作業ツリーへ到達できない: `locked` で `prunable` が抑止された entry に加え、
  ///     `prunable` でも入れないディレクトリ、または祖先の探索権限が無い entry がここへ来る
  ///     (Issue #496)。prunable は事前判定済みなので `rev-parse` を走らせず admin 側で照合する。
  ///     stderr の文言ではなく作業ツリーの到達可能性で判定するのは、git のメッセージが版と
  ///     locale で変わるためである。非 prunable で到達可能性を確かめるのは、git が exit code を
  ///     返した失敗 (`commandFailed`) に限る。git が終了しなかった失敗は不在の証拠にならず、述語が
  ///     打ち切れない FS 呼び出しに入る (`isReachableWorkingTree`)。確かめなかった失敗も、
  ///     到達できた作業ツリーでの失敗も `GitWorktreeEntryFailure.Reason.gitDirectory` に回す。
  ///     到達不能なら common dir 配下の `worktrees/*/gitdir` と作業ツリーパスを照合し、対応した
  ///     admin ディレクトリを安定 ID として返す。対応を特定できなければ ID を推測しない。
  ///   - common dir がこの Project のものでない: 登録済み worktree のディレクトリが別の
  ///     repository に置き換わると、git は `prunable` を付けず、`rev-parse` も exit 0 で
  ///     **その別 repository の** git ディレクトリを返す (git 2.50.1 実測)。そのまま通すと
  ///     Project Root が2件になり、安定 ID が別 Project の `.git` を指して tmux session 名まで
  ///     衝突し得る。この Project の worktree ではないので、失敗ではなく不在として扱う。
  ///   - main worktree でない entry が entry 自身でない git ディレクトリへ解決した: lock された
  ///     worktree の `.git` が消えても入れるディレクトリなら、`rev-parse` は祖先へ遡って exit 0 で
  ///     祖先の repository を返す (Issue #502)。そのまま通すと偽の Project Root や ID の重複になり、
  ///     祖先が別 repository なら上の `.absent` に当たって黙って消えるため、common dir の照合より
  ///     **先に**、同じ `rev-parse` に足した `--is-bare-repository` と `--show-prefix` で確かめ、
  ///     `GitWorktreeEntryFailure.Reason.resolvedToAncestorRepository` で返す (判定の順はそちら)。
  ///     パスは比べない。main worktree かどうかを2行の一致では決められないので、`worktree list`
  ///     の順序で渡す。
  private func describe(
    _ entry: GitWorktreeEntry,
    isMainWorktree: Bool,
    projectCommonDirectory: WorktreeIdentity
  ) async throws(GitWorktreeScanError) -> EntryOutcome {
    if entry.prunableReason != nil {
      return describeUnreachable(entry, projectCommonDirectory: projectCommonDirectory)
    }
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
      stdout = try await runner.run(
        GitReadCommand(
          arguments: isMainWorktree ? Self.gitDirectoryArguments : Self.linkedWorktreeArguments),
        timeout: entryTimeout
      ).stdout
    } catch {
      if case .commandFailed = error, !isWorktreeReachable(entry.path) {
        return describeUnreachable(entry, projectCommonDirectory: projectCommonDirectory)
      }
      return .failed(entry.path, .gitDirectory(error))
    }

    let paths = Self.outputLines(stdout, isMainWorktree: isMainWorktree)
    guard paths.count == (isMainWorktree ? 2 : 4) else {
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
    if !isMainWorktree,
      let failure = Self.ancestorResolution(
        paths, output: stdout, identity: identity, commonDirectory: commonDirectory,
        projectCommonDirectory: projectCommonDirectory)
    {
      return .failed(entry.path, failure)
    }
    guard commonDirectory == projectCommonDirectory else { return .absent }

    return .detected(
      DetectedWorktree(
        identity: identity,
        worktreePath: entry.path,
        branch: entry.branch.map(Self.shortBranchName),
        isProjectRoot: identity == commonDirectory,
        isReachable: true
      ))
  }

  /// main の2行は `split` で分ける (空の行を捨てる)。main でない entry の4行目 (`--show-prefix`)
  /// は作業ツリーの根で空行になるので (git 2.50.1 実測: 3行目以降が `false\n\n`)、空の要素を保ち、
  /// 末尾の改行1つだけを落として分ける。末尾が改行でない出力は行数の検査で弾く。
  private static func outputLines(_ stdout: String, isMainWorktree: Bool) -> [Substring] {
    if isMainWorktree { return stdout.split(separator: "\n") }
    guard stdout.hasSuffix("\n") else { return [] }
    return stdout.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
  }

  /// 判定の順と計測は `GitWorktreeEntryFailure.Reason.resolvedToAncestorRepository`。
  private static func ancestorResolution(
    _ lines: [Substring],
    output: String,
    identity: WorktreeIdentity,
    commonDirectory: WorktreeIdentity,
    projectCommonDirectory: WorktreeIdentity
  ) -> GitWorktreeEntryFailure.Reason? {
    if identity == commonDirectory && commonDirectory == projectCommonDirectory {
      return .resolvedToAncestorRepository
    }
    switch lines[2] {
    case "true": return .resolvedToAncestorRepository
    case "false": return lines[3].isEmpty ? nil : .resolvedToAncestorRepository
    default: return .unexpectedGitDirectoryOutput(output: output)
    }
  }

  private func describeUnreachable(
    _ entry: GitWorktreeEntry,
    projectCommonDirectory: WorktreeIdentity
  ) -> EntryOutcome {
    guard let identity = findAdministrativeDirectory(entry.path, projectCommonDirectory) else {
      return .failed(entry.path, .administrativeDirectoryNotFound)
    }
    return .detected(
      DetectedWorktree(
        identity: identity,
        worktreePath: entry.path,
        branch: entry.branch.map(Self.shortBranchName),
        isProjectRoot: false,
        isReachable: false
      ))
  }

  /// `<common>/worktrees/<作業ツリー名>` を文字列連結せずに列挙して照合するのは、git が管理
  /// ディレクトリ名をサニタイズするためである (git 2.50.1 実測: `wt2 with space` →
  /// `worktrees/wt2-with-space`)。名前から組み立てた文字列は実際の安定 ID と一致しない。
  ///
  /// 照合に失敗したとき作業ツリーパスを代替 ID にしないのは、それが `git worktree move` で変わる
  /// 値だからである (`WorktreeIdentity`)。推測した ID を配ると、復帰したときに同じ worktree だと
  /// 判定できず、`reconcileDetectedWorktrees` から見て消失 → 新規出現になる。
  ///
  /// 作業ツリーへ chdir できなくてもこの経路が成立するのは、読むのが Project Root 側の common dir
  /// 配下だけだからである (git 2.50.1 実測: lock 済みで作業ツリーを消した worktree でも
  /// `<common>/worktrees/<name>/gitdir` はそのまま読める)。
  ///
  /// - Important: 返す安定 ID を正規化せず、`contentsOfDirectory` が返した URL の `path` を
  ///   そのまま渡す。`standardizedFileURL` は結果が実在パスになるときに `/private` 接頭辞を
  ///   落とすため (macOS 26.5 実測: 実在する `/private/tmp/x/.git/worktrees/w` →
  ///   `/tmp/x/.git/worktrees/w`、実在しない同名パスはそのまま)、到達可能なときに
  ///   `rev-parse --path-format=absolute --git-dir` が返す `/private/...` とバイト列が食い違い、
  ///   同じ worktree が2つの ID・2つの tmux session 名を持つ。`URL(fileURLWithPath:)` を通し直す
  ///   のも同じ理由で不可で、macOS 26.5 実測では NFC の `café` が NFD (`caf` + U+0301) へ
  ///   正規化される一方、git は NFC のまま返す。照合側の `standardizedFileURL` は両辺へ等しく
  ///   効くので残す。
  /// - Note: `isReachableWorkingTree` と同じく、打ち切る手段の無い同期 FS I/O をここでも行う。
  ///   `contentsOfDirectory` と `Data(contentsOf:)` はどちらも timeout も cancellation も取らない。
  ///   到達不能と分かった entry に加え、同じ安定 ID の組では到達可能な entry にも呼ばれる。
  ///   読む先は Project Root 側であって作業ツリーではないので、応答しないマウント上の作業ツリーで
  ///   ここが詰まることは無い。
  static func administrativeDirectory(
    worktreePath: String,
    commonDirectory: WorktreeIdentity
  ) -> WorktreeIdentity? {
    let worktreesDirectory = URL(fileURLWithPath: commonDirectory.rawValue)
      .appending(path: "worktrees", directoryHint: .isDirectory)
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: worktreesDirectory,
        includingPropertiesForKeys: nil,
        options: []
      )
    else { return nil }

    let expectedPath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
    for candidate in candidates {
      let gitdir = candidate.appending(path: "gitdir", directoryHint: .notDirectory)
      guard let data = try? Data(contentsOf: gitdir) else { continue }
      // 改行までを1行目とする。`split` は空要素を落とすため、先頭が空行だと2行目を拾ってしまう。
      // 作業ツリーのパス自体が改行を含む場合はここで切れて照合が外れるが、それは
      // `administrativeDirectoryNotFound` になるだけで、誤った ID は配らない。
      let recorded = String(decoding: data, as: UTF8.self).prefix { $0 != "\n" }
      guard !recorded.isEmpty else { continue }
      let recordedPath = Self.resolve(gitdirEntry: String(recorded), from: candidate)
      guard recordedPath == expectedPath else { continue }
      return WorktreeIdentity(rawValue: candidate.path)
    }
    return nil
  }

  /// `worktree.useRelativePaths=true` / `worktree add --relative-paths` で作った worktree では、
  /// `gitdir` の中身は管理ディレクトリからの相対パスになる (git 2.50.1 実測:
  /// `../../../../rel1/.git`)。基準を与えずに `URL(fileURLWithPath:)` へ渡すとプロセスの cwd で
  /// 解決され、照合が必ず外れる。
  ///
  /// 相対の解決に `relativeTo:` ではなく `appending(path:)` を使うのは、前者が基準 URL の
  /// ディレクトリ扱いに依存し、`hasDirectoryPath` が false の基準では最後の要素を捨てて
  /// 静かに別のパスを返すためである (macOS 26.5 実測: 同じパスから作った基準でも、
  /// `isDirectory: false` だと `/tmp/x/.git/worktrees/rel1` 基準の `../../../../rel1/.git` が
  /// `/private/tmp/rel1` になる)。
  private static func resolve(gitdirEntry: String, from administrativeDirectory: URL) -> String {
    let gitDirectory =
      gitdirEntry.hasPrefix("/")
      ? URL(fileURLWithPath: gitdirEntry)
      : administrativeDirectory.appending(path: gitdirEntry)
    return gitDirectory.deletingLastPathComponent().standardizedFileURL.path
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
