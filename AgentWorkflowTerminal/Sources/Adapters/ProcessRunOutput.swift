import Foundation

public enum ProcessRunOutput: Sendable, Equatable {
  case completed(ProcessRunResult)
  /// 子の停止・回収後に返すが、終了コードは結果として扱わない。
  case truncated(stdout: String, stderr: String, limit: Int)
}

extension ProcessRunning {
  public func runTruncatingAtOutputLimit(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunOutput {
    .completed(
      try await run(
        executableURL: executableURL, arguments: arguments, environment: environment,
        timeout: timeout, outputLimit: outputLimit))
  }

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    try await run(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      timeout: timeout,
      outputLimit: ProcessRunLimits.defaultOutputBytes
    )
  }
}

#if os(macOS)
extension FoundationProcessRunner {
  public func runTruncatingAtOutputLimit(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunOutput {
    try await execute(
      ProcessExecution(
        executableURL: executableURL, arguments: arguments, environment: environment,
        timeout: timeout, outputLimit: outputLimit), truncatingAtOutputLimit: true)
  }

  func execute(
    _ execution: ProcessExecution, truncatingAtOutputLimit: Bool
  ) async throws(ProcessRunnerError) -> ProcessRunOutput {
    let result = await withTaskCancellationHandler {
      await execution.runOutput(truncatingAtOutputLimit: truncatingAtOutputLimit)
    } onCancel: {
      Task {
        await execution.cancel()
      }
    }
    if Task.isCancelled {
      await execution.cancel()
      throw .cancelled
    }
    return try result.get()
  }
}
#endif
