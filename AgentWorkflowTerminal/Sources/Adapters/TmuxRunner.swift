import Foundation

public enum TmuxRunnerError: Error, Sendable, Equatable {
  case invalidSocketName(String)
  case binaryNotFound(candidates: [URL])
  case process(ProcessRunnerError)
  case commandFailed(exitCode: Int32, stdout: String, stderr: String)
}

public struct TmuxRunner: Sendable {
  public static let defaultExecutableCandidates = [
    URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
    URL(fileURLWithPath: "/usr/local/bin/tmux"),
    URL(fileURLWithPath: "/usr/bin/tmux"),
  ]

  // ローカル socket への通常操作は即時に終わるため、異常な server 停止を10秒で打ち切る。
  public static let defaultTimeout = Duration.seconds(10)

  private static let inheritedEnvironmentKeys = ["HOME", "PATH", "TMUX_TMPDIR"]

  private let socketName: String
  private let processRunner: any ProcessRunning
  private let executableURL: URL
  private let environment: [String: String]

  public init(
    socketName: String,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = Self.defaultExecutableCandidates
  ) throws(TmuxRunnerError) {
    try self.init(
      socketName: socketName,
      processRunner: processRunner,
      executableCandidates: executableCandidates,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) }
    )
  }

  init(
    socketName: String,
    processRunner: any ProcessRunning,
    executableCandidates: [URL],
    parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
  ) throws(TmuxRunnerError) {
    guard !socketName.isEmpty, !socketName.contains("/") else {
      throw .invalidSocketName(socketName)
    }
    guard let executableURL = executableCandidates.first(where: isExecutableFile) else {
      throw .binaryNotFound(candidates: executableCandidates)
    }

    self.socketName = socketName
    self.processRunner = processRunner
    self.executableURL = executableURL

    var environment = ["LC_ALL": "C"]
    // tmux 3.4 では TMUX_TMPDIR だけが -L の socket 親を変え、TMPDIR は影響しなかった。
    for key in Self.inheritedEnvironmentKeys {
      if let value = parentEnvironment[key] {
        environment[key] = value
      }
    }
    // これは出力解析クライアント用。new-session に流用すると、この限定環境が全 pane へ継承される
    // ことを tmux 3.4 の隔離 server で実測しているため、server 起動時の環境は別途設計が必要。
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
        arguments: ["-u", "-L", socketName] + arguments,
        environment: environment,
        timeout: timeout ?? Self.defaultTimeout
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
