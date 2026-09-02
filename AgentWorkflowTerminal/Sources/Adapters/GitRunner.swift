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

  fileprivate var arguments: [String] {
    switch self {
    case .workingTree(let revision): [revision.rawValue]
    case .index(let revision): ["--cached", revision.rawValue]
    case .range(let range): range.arguments
    }
  }
}

/// internal initializer により、モジュール外から書き込み subcommand を注入できない (§17.2)。
public struct GitReadCommand: Sendable, Equatable {
  public let arguments: [String]

  // 明示的な access level が書き込み command を外部から作れない保証そのものになる。
  // swiftlint:disable:next unneeded_synthesized_initializer
  init(arguments: [String]) {
    self.arguments = arguments
  }

  public static func status(includeIgnored: Bool = false) -> Self {
    // user config で観測集合と rename 表現が変わらないよう、形式決定用 option を固定する。
    var arguments = [
      "status", "--porcelain=v2", "--branch", "--renames", "--untracked-files=normal", "-z",
    ]
    if includeIgnored { arguments.append("--ignored=matching") }
    return Self(arguments: arguments)
  }

  public static func worktreeList() -> Self {
    Self(arguments: ["worktree", "list", "--porcelain", "-z"])
  }

  public static func log(
    range: GitRevisionRange? = nil,
    maxCount: Int? = nil,
    pathspec: [GitPathspec] = []
  ) -> Self {
    // 0 以下は option を付けず、件数を制限しない。
    var arguments = ["log", "-z", "--no-show-signature", "--format=" + GitLog.format]
    if let maxCount, maxCount > 0 { arguments.append("--max-count=\(maxCount)") }
    arguments += range?.arguments ?? []
    arguments.append("--")
    arguments += pathspec.map(\.rawValue)
    return Self(arguments: arguments)
  }

  public static func diffFileSummaries(
    _ target: GitDiffTarget, pathspec: [GitPathspec] = []
  ) -> Self {
    diff(
      [
        "--no-ext-diff", "--no-textconv", "--find-renames", "--raw", "--numstat", "--no-abbrev",
        "-z",
      ],
      target,
      pathspec)
  }

  public static func diffPatch(_ target: GitDiffTarget, pathspec: [GitPathspec] = []) -> Self {
    diff(
      ["--no-ext-diff", "--no-textconv", "--find-renames", "--patch", "--no-color"],
      target,
      pathspec)
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
