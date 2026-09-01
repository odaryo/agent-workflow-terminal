import Darwin
import Foundation

public struct ProcessRunResult: Sendable, Equatable {
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String

  public init(exitCode: Int32, stdout: String, stderr: String) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
  case launchFailed(executableURL: URL, message: String)
  case timedOut
  case cancelled
  case outputReadFailed(message: String)
}

public protocol ProcessRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration
  ) async throws(ProcessRunnerError) -> ProcessRunResult
}

public struct FoundationProcessRunner: ProcessRunning, Sendable {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    let execution = ProcessExecution(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      timeout: timeout
    )

    do {
      return try await withTaskCancellationHandler {
        try await execution.run()
      } onCancel: {
        Task {
          await execution.cancel()
        }
      }
    } catch let error as ProcessRunnerError {
      throw error
    } catch {
      throw .outputReadFailed(message: String(describing: error))
    }
  }
}

private actor ProcessExecution {
  // SIGTERM で通常の後始末を促しつつ、テストを秒単位で遅らせない猶予。
  private static let terminationGracePeriod = Duration.milliseconds(100)

  private enum StopReason {
    case timedOut
    case cancelled
  }

  private struct ProcessResources {
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
  }

  private let executableURL: URL
  private let arguments: [String]
  private let environment: [String: String]
  private let timeout: Duration

  private var process: Process?
  private var terminationContinuation: CheckedContinuation<Void, Never>?
  private var didTerminate = false
  private var stopReason: StopReason?
  private var isStopping = false

  init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.timeout = timeout
  }

  func run() async throws(ProcessRunnerError) -> ProcessRunResult {
    guard !Task.isCancelled else {
      throw .cancelled
    }

    let resources = makeProcess()
    let process = resources.process

    do {
      try process.run()
    } catch {
      self.process = nil
      throw .launchFailed(executableURL: executableURL, message: String(describing: error))
    }

    // 子が一方のパイプを埋めても他方の読み取りを妨げないよう、独立した Task で drain する。
    let stdoutTask = Task.detached {
      try resources.stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
    }
    let stderrTask = Task.detached {
      try resources.stderrPipe.fileHandleForReading.readToEnd() ?? Data()
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await stop(for: .timedOut)
    }

    await waitForTermination()
    timeoutTask.cancel()
    reap(process)

    let stdoutData: Data
    let stderrData: Data
    do {
      stdoutData = try await stdoutTask.value
      stderrData = try await stderrTask.value
    } catch {
      self.process = nil
      if Task.isCancelled || stopReason == .cancelled {
        throw .cancelled
      }
      if stopReason == .timedOut {
        throw .timedOut
      }
      throw .outputReadFailed(message: String(describing: error))
    }
    self.process = nil

    if Task.isCancelled || stopReason == .cancelled {
      throw .cancelled
    }
    if stopReason == .timedOut {
      throw .timedOut
    }

    return ProcessRunResult(
      exitCode: process.terminationStatus,
      stdout: String(decoding: stdoutData, as: UTF8.self),
      stderr: String(decoding: stderrData, as: UTF8.self)
    )
  }

  func cancel() async {
    await stop(for: .cancelled)
  }

  private func makeProcess() -> ProcessResources {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { [weak self] _ in
      guard let self else { return }
      Task {
        await self.processDidTerminate()
      }
    }
    self.process = process
    return ProcessResources(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
  }

  private func stop(for reason: StopReason) async {
    if reason == .cancelled || stopReason == nil {
      stopReason = reason
    }
    guard let process, process.isRunning, !isStopping else { return }
    isStopping = true

    process.terminate()
    do {
      try await Task.sleep(for: Self.terminationGracePeriod)
    } catch {
      // 終了手順そのものは呼び出し元 Task のキャンセルに左右されない。
    }
    if process.isRunning {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    reap(process)
  }

  private func waitForTermination() async {
    if didTerminate {
      return
    }
    await withCheckedContinuation { continuation in
      if didTerminate {
        continuation.resume()
      } else {
        terminationContinuation = continuation
      }
    }
  }

  private func processDidTerminate() {
    didTerminate = true
    terminationContinuation?.resume()
    terminationContinuation = nil
  }

  private func reap(_ process: Process) {
    process.waitUntilExit()
  }
}
