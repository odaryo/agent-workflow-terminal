import Foundation

public enum TmuxRunnerError: Error, Sendable, Equatable {
  case invalidSocketName(String)
  case binaryNotFound(candidates: [URL])
  case process(ProcessRunnerError)
  case commandFailed(exitCode: Int32, stdout: String, stderr: String)
}

/// どの tmux server へ接続するか。
///
/// アプリ本体は `userDefault` を使う。ユーザーが素の端末から `tmux attach -t <session>` で
/// 同じ session へ入れること、つまりアプリが観測する実体とユーザーが自分の端末で見る実体が
/// 一致することが製品の前提であるため (設計書 §4.1)。`socketName` は隔離 server を使う
/// テストとスパイクのためにあり、こちらを選ぶとユーザー側は毎回 `-L` を要求される。
///
/// - Note: tmux 3.4 実測では、`TMUX_TMPDIR` は **`-L` を付けたときだけ** socket の親を変え、
///   `-L` 無しの既定 server は `TMUX_TMPDIR` / `TMPDIR` を設定しても
///   `/tmp/tmux-<uid>/default` のままだった。したがって、この型が子へ渡す `TMUX_TMPDIR` が
///   `userDefault` の接続先を動かすことはない。socket 以外では、GUI 起動のアプリがシェル rc を
///   経ていない環境を持つという差が残る。その環境をどう組み立てるかは Issue #61 の担当。
public enum TmuxServer: Sendable, Hashable {
  case userDefault
  case socketName(String)
}

public struct TmuxRunner: Sendable {
  // MacPorts / Nix の設置場所は推測せず、非標準配置は initializer の注入で扱う。
  public static let defaultExecutableCandidates = [
    URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
    URL(fileURLWithPath: "/usr/local/bin/tmux"),
    URL(fileURLWithPath: "/usr/bin/tmux"),
  ]

  // ローカル socket への通常操作は即時に終わるため、異常な server 停止を10秒で打ち切る。
  public static let defaultTimeout = Duration.seconds(10)
  public static let defaultOutputLimit = ProcessRunLimits.defaultOutputBytes

  private static let inheritedEnvironmentKeys = ["HOME", "PATH", "TMUX_TMPDIR"]

  /// サブコマンドより前に置く global option。`-L` を持たない `userDefault` では `-u` だけになる。
  private let serverArguments: [String]
  private let processRunner: any ProcessRunning
  private let executableURL: URL
  private let environment: [String: String]

  public init(
    server: TmuxServer,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = Self.defaultExecutableCandidates
  ) throws(TmuxRunnerError) {
    try self.init(
      server: server,
      processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) }
    )
  }

  public init(
    socketName: String,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = Self.defaultExecutableCandidates
  ) throws(TmuxRunnerError) {
    try self.init(
      server: .socketName(socketName),
      processRunner: processRunner,
      executableCandidates: executableCandidates
    )
  }

  init(
    socketName: String,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
  ) throws(TmuxRunnerError) {
    try self.init(
      server: .socketName(socketName),
      processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: parentEnvironment,
      isExecutableFile: isExecutableFile
    )
  }

  init(
    server: TmuxServer,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
  ) throws(TmuxRunnerError) {
    // socket 名の検証は `-L` を渡すときだけ意味を持つ。既定 server には socket 名が無い。
    if case .socketName(let socketName) = server {
      guard !socketName.isEmpty, !socketName.contains("/") else {
        throw .invalidSocketName(socketName)
      }
    }
    guard let executableURL = executableCandidates.first(where: isExecutableFile) else {
      throw .binaryNotFound(candidates: executableCandidates)
    }

    self.serverArguments =
      switch server {
      case .userDefault: ["-u"]
      case .socketName(let socketName): ["-u", "-L", socketName]
      }
    self.processRunner = processRunner
    self.executableURL = executableURL

    var environment = ["LC_ALL": "C"]
    // tmux 3.4 では TMUX_TMPDIR だけが -L の socket 親を変え、TMPDIR は影響しなかった。
    for key in Self.inheritedEnvironmentKeys {
      if let value = parentEnvironment[key] {
        environment[key] = value
      }
    }
    // この入口は出力解析クライアント用だが、new-session も通せるため限定環境が server に
    // 保持され全 pane へ継承され得る。現状 API では防がず、分離は Issue #61 で設計する。
    self.environment = environment
  }

  public func run(
    arguments: [String],
    timeout: Duration? = nil,
    outputLimit: Int = Self.defaultOutputLimit
  ) async throws(TmuxRunnerError) -> ProcessRunResult {
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: executableURL,
        arguments: serverArguments + arguments,
        environment: environment,
        timeout: timeout ?? Self.defaultTimeout,
        outputLimit: outputLimit
      )
    } catch {
      throw .process(error)
    }

    guard result.exitCode == 0 else {
      throw .commandFailed(
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr
      )
    }
    return result
  }
}

extension TmuxRunner {
  /// tmux 1.5 以前の `-V` 非対応を含む実行失敗も版数不明を表すため、支援状態へ丸めず
  /// `TmuxRunnerError` として返す。
  public func version(
    timeout: Duration? = nil
  ) async throws(TmuxRunnerError)
    -> TmuxVersionSupport
  {
    let result = try await run(arguments: ["-V"], timeout: timeout)
    return TmuxVersion.support(for: TmuxVersion.parse(versionOutput: result.stdout))
  }
}
