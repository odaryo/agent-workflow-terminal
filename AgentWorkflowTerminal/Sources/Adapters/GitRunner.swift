import Foundation

public enum GitRunnerError: Error, Sendable, Equatable {
  case binaryNotFound(candidates: [URL])
  case invalidRepositoryDirectory(URL)
  case process(ProcessRunnerError)
  case commandFailed(exitCode: Int32, stdout: String, stderr: String)
}

public struct GitRevision: Sendable, Equatable, Hashable {
  public let rawValue: String

  public init?(_ rawValue: String) {
    guard !rawValue.isEmpty, rawValue.first != "-", rawValue.first != ".",
      !rawValue.contains("\0"), !rawValue.contains("\n")
    else { return nil }
    self.rawValue = rawValue
  }

  private init(validated rawValue: String) { self.rawValue = rawValue }
  public static let head = Self(validated: "HEAD")
}

public struct GitPathspec: Sendable, Equatable, Hashable {
  public let rawValue: String

  public init?(_ rawValue: String) {
    guard !rawValue.isEmpty, rawValue.first != "-", !rawValue.contains("\0"),
      !rawValue.contains("\n")
    else { return nil }
    self.rawValue = rawValue
  }
}

public struct GitRevisionRange: Sendable, Equatable {
  private enum Separator: String, Sendable { case twoDot = "..", threeDot = "..." }
  private let from: GitRevision
  private let to: GitRevision
  private let separator: Separator

  public static func twoDot(from: GitRevision, to: GitRevision) -> Self {
    Self(from: from, to: to, separator: .twoDot)
  }

  public static func threeDot(from: GitRevision, to: GitRevision) -> Self {
    Self(from: from, to: to, separator: .threeDot)
  }

  var arguments: [String] { [from.rawValue + separator.rawValue + to.rawValue] }
}

/// §25 で未確定の Diff の意味を Adapter が選ばないよう、呼び出し側が比較対象を明示する。
public enum GitDiffTarget: Sendable, Equatable {
  case workingTree(against: GitRevision)
  case index(against: GitRevision)
  case range(GitRevisionRange)
  /// index と working tree の比較 (= revision を渡さない `git diff`)。`workingTree(against:)` は
  /// staged と unstaged が混ざるため、§9.1.3 の4区分には使えない。
  case unstaged

  fileprivate var arguments: [String] {
    switch self {
    case .workingTree(let revision): [revision.rawValue]
    case .index(let revision): ["--cached", revision.rawValue]
    case .range(let range): range.arguments
    case .unstaged: []
    }
  }
}

/// `normal` は未追跡 directory を末尾 `/` の1件へ畳む。Diff はファイル単位の差分を要るので
/// `all` を選ぶ (§9.1.3)。既定を変えないのは、File Browser 側が件数の爆発を避けているため。
public enum GitUntrackedFilesMode: String, Sendable, Equatable {
  case normal
  case all
}

/// internal initializer により、モジュール外から書き込み subcommand を注入できない (§17.2)。
public struct GitReadCommand: Sendable, Equatable {
  public let arguments: [String]

  // 明示的な access level が書き込み command を外部から作れない保証そのものになる。
  // swiftlint:disable:next unneeded_synthesized_initializer
  init(arguments: [String]) {
    self.arguments = arguments
  }

  public static func status(
    includeIgnored: Bool = false,
    untrackedFiles: GitUntrackedFilesMode = .normal
  ) -> Self {
    // user config で観測集合と rename 表現が変わらないよう、形式決定用 option を固定する。
    // --renames は git 2.18 以降。サポート下限の決定は Issue #83 に委ねる。
    // `--ignore-submodules=none` が無いと `diff.ignoreSubmodules=all` で gitlink の変更が
    // 出力から消える (git 2.50.1 で実測: 巻き戻した gitlink があるのに entry ゼロ)。
    // `status` に `--submodule` は無い (実測: `error: unknown option`)。
    var arguments = [
      "status", "--porcelain=v2", "--branch", "--renames", "--ignore-submodules=none",
      "--untracked-files=" + untrackedFiles.rawValue, "-z",
    ]
    if includeIgnored { arguments.append("--ignored=matching") }
    return Self(arguments: arguments)
  }

  /// サブモジュールの所在は index が正本。変更の無いサブモジュールは `status` に一切現れない。
  public static func listFilesStage() -> Self {
    // -z は status と同じ理由 — パス名の quoting を避ける。
    Self(arguments: ["ls-files", "--stage", "-z"])
  }

  public static func worktreeList() -> Self {
    Self(arguments: ["worktree", "list", "--porcelain", "-z"])
  }

  public static func originHead() -> Self {
    Self(arguments: ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
  }

  /// `--is-ancestor` は真偽しか返さないので、range を組むための OID はこちらで取る (§9.1.2)。
  public static func mergeBase(_ first: GitRevision, _ second: GitRevision) -> Self {
    Self(arguments: ["merge-base", first.rawValue, second.rawValue])
  }

  /// 親を持たない commit の比較対象。`-w` を付けないので object は書き込まれない。
  /// hash 算法 (sha1 / sha256) ごとに値が違うため、定数を埋め込まず repository へ問い合わせる。
  public static func emptyTreeObject() -> Self {
    Self(arguments: ["hash-object", "-t", "tree", "/dev/null"])
  }

  /// base branch の選び直し (§9.1.1) と Branch Diff の対象選択に使う一覧。
  public static func listRefs() -> Self {
    Self(arguments: ["for-each-ref", "--format=%(refname)", "refs/heads/", "refs/remotes/"])
  }

  public static func isAncestor(_ ancestor: GitRevision, of descendant: GitRevision) -> Self {
    Self(arguments: ["merge-base", "--is-ancestor", ancestor.rawValue, descendant.rawValue])
  }

  public static func log(
    range: GitRevisionRange? = nil,
    maxCount: Int? = nil,
    pathspec: [GitPathspec] = []
  ) -> Self {
    // 0 以下は option を付けず、件数を制限しない。
    // --no-show-signature は man page に無い否定形だが、user config の署名出力混入を止める。
    var arguments = [
      "log", "-z", "--no-show-signature", "--encoding=UTF-8", "--format=" + GitLog.format,
    ]
    if let maxCount, maxCount > 0 { arguments.append("--max-count=\(maxCount)") }
    arguments += range?.arguments ?? []
    arguments.append("--")
    arguments += pathspec.map(\.rawValue)
    return Self(arguments: arguments)
  }

  public static func diffFileSummaries(
    _ target: GitDiffTarget, pathspec: [GitPathspec] = []
  ) -> Self {
    // --no-abbrev は man page に無い否定形。--full-index は patch の index 行にしか効かず、
    // raw OID を config 非依存の完全長にする代替にはならない。
    // `--ignore-submodules=none` は `diff.ignoreSubmodules=all` による gitlink 欠落を止める。
    // `--submodule` は付けない — raw / numstat は gitlink を常に1件として出すため、
    // `diff.submodule` の値で出力が変わらないことを実測した。
    diff(
      [
        "--no-ext-diff", "--no-textconv", "--find-renames", "--raw", "--numstat", "--no-abbrev",
        "--ignore-submodules=none", "-z",
      ],
      target,
      pathspec)
  }

  public static func diffPatch(_ target: GitDiffTarget, pathspec: [GitPathspec] = []) -> Self {
    // patch には -z が無く、path の表現が user config で動く。`core.quotePath=false` は非 ASCII の
    // 8進 escape を止め、`--src-prefix` / `--dst-prefix` は `diff.noprefix` /
    // `diff.mnemonicprefix` を上書きする (git 2.50.1 で実測)。どちらもパーサの前提を固定する。
    // `--full-index` は `index` 行の OID を `core.abbrev` から切り離す (実測: `core.abbrev=4` で
    // `index 7898..422c`、`=12` で `index 78981922613b..422c2b7ab3b3`)。この OID は差分行を
    // 持たないファイルの同一性そのものなので、桁数が動くと §9.3 の変更検知が偽陽性・偽陰性を出す。
    // `--submodule=short` が無いと `diff.submodule=diff` で **別 repository (submodule 内) の
    // ファイル**が worktree の変更として並び、その行に付いたコメントがこの worktree に無い
    // パスを指す (§9.2 の誤送信)。`=log` では gitlink の変更が解析不能な1件に化ける。
    // `--ignore-submodules=none` は `diff.ignoreSubmodules=all` による gitlink 欠落を止める。
    let patched = diff(
      [
        "--no-ext-diff", "--no-textconv", "--find-renames", "--patch", "--no-color",
        "--full-index", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short",
        "--ignore-submodules=none",
      ],
      target,
      pathspec)
    return Self(arguments: ["-c", "core.quotePath=false"] + patched.arguments)
  }

  private static func diff(
    _ options: [String], _ target: GitDiffTarget, _ pathspec: [GitPathspec]
  ) -> Self {
    Self(arguments: ["diff"] + options + target.arguments + ["--"] + pathspec.map(\.rawValue))
  }
}

public struct GitRunner: Sendable {
  public static let defaultExecutableCandidates = [
    URL(fileURLWithPath: "/opt/homebrew/bin/git"), URL(fileURLWithPath: "/usr/local/bin/git"),
    URL(fileURLWithPath: "/usr/bin/git"),
  ]
  // MacPorts / Nix の設置場所は推測せず、非標準配置は initializer の注入で扱う。
  // 大規模 repository の log / diff は I/O 律速で秒単位になり得るため tmux より長く待つ。
  public static let defaultTimeout = Duration.seconds(30)
  public static let defaultOutputLimit = ProcessRunLimits.defaultOutputBytes
  // `ls-files --stage -z` の出力量は変更集合ではなく index の大きさに比例する。1 entry は
  // 計測で 51 バイト + パス長 (パス 29 文字なら 80 バイト) なので、既定の 8 MiB は約 10 万 entry で
  // 尽きる。64 MiB は同じ見積りで約 80 万 entry にあたる。
  public static let indexListingOutputLimit = 64 << 20
  // patch の出力量は変更集合の大きさに比例する。計測: 220,000 行 (10.7 MB) のファイルを1つ
  // `git add` しただけで staged patch が 10,889,014 バイトになり、既定の 8 MiB では
  // その worktree の Diff が丸ごと開けなくなる (§9.1.3 は未 commit の変更も含めると定めている)。
  // 64 MiB は同じ見積りで約 130 万行にあたる。
  public static let diffPatchOutputLimit = 64 << 20

  private let repositoryDirectory: URL
  private let processRunner: any ProcessRunning
  private let executableURL: URL
  private let environment: [String: String]

  public init(
    repositoryDirectory: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = Self.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    try self.init(
      repositoryDirectory: repositoryDirectory, processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) })
  }

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
    // global/system config は include.path 等を保つ。出力形式に効く config は各 command の
    // 明示 option で固定し、意味を選ぶ range 等とは区別する。
    self.environment = environment
  }

  public func run(
    _ command: GitReadCommand,
    timeout: Duration? = nil,
    outputLimit: Int = Self.defaultOutputLimit
  ) async throws(GitRunnerError) -> ProcessRunResult {
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: executableURL,
        arguments: ["--no-optional-locks", "-C", repositoryDirectory.path, "--no-pager"]
          + command.arguments,
        environment: environment, timeout: timeout ?? Self.defaultTimeout,
        outputLimit: outputLimit)
    } catch { throw .process(error) }
    guard result.exitCode == 0 else {
      throw .commandFailed(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }
    return result
  }
}
