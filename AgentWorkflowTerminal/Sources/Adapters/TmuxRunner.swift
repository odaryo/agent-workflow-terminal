import Foundation

public enum TmuxRunnerError: Error, Sendable, Equatable {
  case binaryNotFound(candidates: [URL])
  case process(ProcessRunnerError)
  case commandFailed(exitCode: Int32, stderr: String)
}

public actor TmuxRunner {
  public static let defaultExecutableCandidates = [
    URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
    URL(fileURLWithPath: "/usr/local/bin/tmux"),
    URL(fileURLWithPath: "/usr/bin/tmux"),
  ]

  // ローカル socket への通常操作は即時に終わるため、異常な server 停止を10秒で打ち切る。
  public static let defaultTimeout = Duration.seconds(10)

  private static let inheritedEnvironmentKeys = ["HOME", "PATH", "TMPDIR"]

  private let socketName: String
  private let processRunner: any ProcessRunning
  private let executableURL: URL
  private let environment: [String: String]

  public init(
    socketName: String,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = TmuxRunner.defaultExecutableCandidates,
    isExecutableFile: @Sendable (URL) -> Bool = {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  ) throws(TmuxRunnerError) {
    guard let executableURL = executableCandidates.first(where: isExecutableFile) else {
      throw .binaryNotFound(candidates: executableCandidates)
    }

    self.socketName = socketName
    self.processRunner = processRunner
    self.executableURL = executableURL

    let parentEnvironment = ProcessInfo.processInfo.environment
    var environment = ["LC_ALL": "C"]
    // LC_ALL だけでは tmux server の保持環境からユーザーの home・コマンド探索先・一時領域が
    // 消えることを tmux 3.4 の隔離 server で実測したため、必要なキーだけを選択継承する。
    for key in Self.inheritedEnvironmentKeys {
      if let value = parentEnvironment[key] {
        environment[key] = value
      }
    }
    self.environment = environment
  }

  public func run(
    arguments: [String],
    timeout: Duration? = nil
  ) async throws(TmuxRunnerError) -> ProcessRunResult {
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: executableURL,
        arguments: ["-L", socketName] + arguments,
        environment: environment,
        timeout: timeout ?? Self.defaultTimeout
      )
    } catch {
      throw .process(error)
    }

    guard result.exitCode == 0 else {
      throw .commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
    return result
  }
}
