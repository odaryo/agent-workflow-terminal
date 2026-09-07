import Foundation
import TerminalCore

public enum RipgrepRunnerError: Error, Sendable, Equatable {
  case binaryNotFound(candidates: [URL])
  case invalidWorktreeRoot(URL)
  /// 出力上限に達した = 表示できないほど広い検索。§8.2 の 1,000 件上限は rg の出力を
  /// 読み切ってから適用するので、rg 側の出力量そのものは別に効いてくる。
  case tooManyResults(outputLimit: Int)
  case timedOut(seconds: Int64)
  case cancelled
  case process(ProcessRunnerError)
  /// rg が探索を始められなかった (正規表現が不正、root を開けない等)。
  case commandFailed(exitCode: Int32, stderr: String)
}

public struct RipgrepCommand: Sendable, Equatable {
  public let arguments: [String]

  // 明示的な access level により、モジュール外から任意の argv を rg へ渡せない。
  // swiftlint:disable:next unneeded_synthesized_initializer
  init(arguments: [String]) {
    self.arguments = arguments
  }

  /// `perFileLimit + 1` を rg へ渡す理由は `RipgrepJSONOutputParser.parse` を参照。
  public static func search(
    _ query: WorktreeSearchQuery,
    worktreeRoot: URL,
    perFileLimit: Int = WorktreeSearchLimits.maximumMatchesPerFile
  ) -> Self {
    var arguments = ["--json", "--no-config", "--smart-case"]
    if perFileLimit > 0 { arguments += ["--max-count", String(perFileLimit + 1)] }
    if !query.usesRegularExpression { arguments.append("--fixed-strings") }
    arguments += scopeArguments(query.scope)
    // `--` を置かないと、`-x` で始まる検索語が option として読まれる。
    arguments += ["--", query.term, worktreeRoot.path]
    return Self(arguments: arguments)
  }

  public static func listFiles(scope: WorktreeSearchScope, worktreeRoot: URL) -> Self {
    // 改行を含むファイル名があっても1件を取り違えないよう NUL 区切りにする。
    Self(
      arguments: ["--files", "--null", "--no-config"] + scopeArguments(scope)
        + ["--", worktreeRoot.path])
  }

  private static func scopeArguments(_ scope: WorktreeSearchScope) -> [String] {
    switch scope {
    case .respectingGitignore:
      // rg の既定は `.gitignore` を尊重し `.git/` も除く (実測 15.2.0)。
      []
    case .allFiles:
      // 末尾スラッシュを付けない。`!.git/` はディレクトリにしかマッチせず、git worktree の
      // `.git` は `gitdir:` を書いた正規ファイルなので素通りする (実測 15.2.0: 実 worktree で
      // `--glob '!.git/'` を付けても `.git` が `--files` と全文検索の両方に現れる)。
      // 1タスク = 1 worktree (§2.1) なので、こちらが通常の実行環境。
      ["--no-ignore", "--hidden", "--glob", "!.git"]
    }
  }
}

public struct RipgrepRunner: Sendable {
  public static let defaultExecutableCandidates = [
    URL(fileURLWithPath: "/opt/homebrew/bin/rg"), URL(fileURLWithPath: "/usr/local/bin/rg"),
    URL(fileURLWithPath: "/usr/bin/rg"),
  ]
  // 3.5 GB / 79,095 ファイルの木を rg 15.2.0 が 2.9 秒で走り切った実測に対する余裕。
  public static let defaultTimeout = Duration.seconds(15)
  // `--json` の1一致は実測で平均 483 バイト (このリポジトリで 373〜506 B、`e` の 14,519 一致で
  // 484.5 B)。既定の 8 MiB は約 1.7 万一致で尽き、1文字クエリが実際に超える (gitignore scope で
  // 7.0 MB、全ファイル scope で 43.5 MB)。上限超過は部分出力を丸ごと捨てるため、
  // §8.2 の 1,000 件上限が効くはずの「一致が多すぎる」場面で 0 件になる。64 MiB は同じ見積りで
  // 約 13.9 万一致にあたり、上の全ファイル scope の実測も収まる。`--files` にも同じ上限を使う
  // (79,123 ファイルの木で 7.1 MB = 既定の 89% と、こちらも 8 MiB では足りない)。
  public static let searchOutputLimit = 64 << 20
  public static let defaultOutputLimit = ProcessRunLimits.defaultOutputBytes

  private let worktreeRoot: URL
  private let processRunner: any ProcessRunning
  private let executableURL: URL
  private let environment: [String: String]

  public init(
    worktreeRoot: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = Self.defaultExecutableCandidates
  ) throws(RipgrepRunnerError) {
    try self.init(
      worktreeRoot: worktreeRoot, processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) })
  }

  init(
    worktreeRoot: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
  ) throws(RipgrepRunnerError) {
    guard worktreeRoot.isFileURL, worktreeRoot.baseURL == nil,
      worktreeRoot.path.hasPrefix("/")
    else {
      throw .invalidWorktreeRoot(worktreeRoot)
    }
    guard let executableURL = executableCandidates.first(where: isExecutableFile) else {
      throw .binaryNotFound(candidates: executableCandidates)
    }
    self.worktreeRoot = worktreeRoot
    self.processRunner = processRunner
    self.executableURL = executableURL
    var environment = ["LC_ALL": "C"]
    for key in ["HOME", "PATH"] where parentEnvironment[key] != nil {
      environment[key] = parentEnvironment[key]
    }
    // `RIPGREP_CONFIG_PATH` は継承しないが、`--no-config` も併せて渡し、設定ファイルで
    // scope や出力形式が変わる余地を argv 側でも閉じる。
    self.environment = environment
  }

  public var root: URL { worktreeRoot }

  /// 終了コードはエラーへ変換しない。rg は 1 = 一致なし、2 = 一部または全部を
  /// 調べられなかった、を返し、2 でも stdout が完全なことがある (実測: 読めない
  /// ディレクトリが1つあるだけで 2 になり、他のファイルの結果は揃っている)。
  /// 「調べられなかった」と「見つからなかった」の区別は呼び出し側が行う (§12.3)。
  public func run(
    _ command: RipgrepCommand,
    timeout: Duration? = nil,
    outputLimit: Int = Self.defaultOutputLimit
  ) async throws(RipgrepRunnerError) -> ProcessRunResult {
    let timeout = timeout ?? Self.defaultTimeout
    do {
      return try await processRunner.run(
        executableURL: executableURL, arguments: command.arguments,
        environment: environment, timeout: timeout, outputLimit: outputLimit)
    } catch {
      switch error {
      case .outputLimitExceeded(let limit):
        throw .tooManyResults(outputLimit: limit)
      case .timedOut:
        throw .timedOut(seconds: timeout.components.seconds)
      case .cancelled:
        throw .cancelled
      default:
        throw .process(error)
      }
    }
  }
}
