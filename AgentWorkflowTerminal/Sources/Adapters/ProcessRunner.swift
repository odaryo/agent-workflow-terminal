import Foundation

#if os(macOS)
import Darwin
#endif

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

public enum ProcessRunLimits {
  // tmux の pane 一覧には十分な余裕を持たせつつ、暴走時の保持量を1実行8 MiBに制限する。
  public static let defaultOutputBytes = 8 * 1_024 * 1_024
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
  case launchFailed(executableURL: URL, message: String)
  case timedOut(exitCode: Int32?, stdout: String, stderr: String)
  case cancelled
  case outputLimitExceeded(limit: Int)
  case outputReadFailed(message: String)
  case invalidOutputLimit(Int)
}

/// 実装は子プロセスへ stdin を渡さない。対話的プロセスは別の境界で駆動する。
public protocol ProcessRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult
}

extension ProcessRunning {
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

// Foundation.Process は macOS でのみ利用でき、実行ホストも Mac に限定する (設計書 §20.1)。
#if os(macOS)
public struct FoundationProcessRunner: ProcessRunning, Sendable {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    guard outputLimit >= 0 else {
      throw .invalidOutputLimit(outputLimit)
    }
    let execution = ProcessExecution(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      timeout: timeout,
      outputLimit: outputLimit
    )

    let result = await withTaskCancellationHandler {
      await execution.run()
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

private actor ProcessExecution {
  // SIGTERM の後始末機会と1秒未満の停止上界を両立する暫定値。CLI 別の猶予は未実測。
  private static let terminationGracePeriod = Duration.milliseconds(100)
  // 期限時点で子が終了済みなら、出力の配達が着地する猶予を与えてから .timedOut を確定する。
  // 配達の遅延は制御できず、この猶予が効いていることを固定するテストは無い (0 でも既存テストは通る)。
  private static let endOfFileGracePeriod = Duration.milliseconds(50)

  private struct OutputPipe {
    let reader: AsyncPipeReader
    let writeHandle: FileHandle
  }

  private struct ProcessResources {
    let process: Process
    let stdout: OutputPipe
    let stderr: OutputPipe
  }

  private let executableURL: URL
  private let arguments: [String]
  private let environment: [String: String]
  private let timeout: Duration
  private let outputLimit: Int
  private let outputBudget: OutputBudget

  private var process: Process?
  private var processWasLaunched = false
  private var stdoutReader: AsyncPipeReader?
  private var stderrReader: AsyncPipeReader?
  private var terminationStatus: Int32?
  private var stdoutSnapshot = AsyncPipeReader.Snapshot.empty
  private var stderrSnapshot = AsyncPipeReader.Snapshot.empty
  private var terminalError: ProcessRunnerError?
  private var finalResult: Result<ProcessRunResult, ProcessRunnerError>?
  private var resultContinuation:
    CheckedContinuation<Result<ProcessRunResult, ProcessRunnerError>, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var endOfFileGraceTask: Task<Void, Never>?
  private var escalationTask: Task<Void, Never>?

  init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.timeout = timeout
    self.outputLimit = outputLimit
    self.outputBudget = OutputBudget(limit: outputLimit)
  }

  func run() async -> Result<ProcessRunResult, ProcessRunnerError> {
    guard !Task.isCancelled else {
      return .failure(.cancelled)
    }

    let resources: ProcessResources
    do {
      resources = try makeProcessResources()
    } catch {
      return .failure(error)
    }
    install(resources)

    do {
      try resources.process.run()
    } catch {
      closeParentWriteHandles(resources)
      let result = Result<ProcessRunResult, ProcessRunnerError>.failure(
        .launchFailed(executableURL: executableURL, message: String(describing: error)))
      complete(result)
      stopReading()
      return result
    }
    processWasLaunched = true
    closeParentWriteHandles(resources)
    startTimeout()
    if Task.isCancelled {
      cancel()
    }

    return await waitForResult()
  }

  func cancel() {
    guard finalResult == nil else { return }
    // 明示的な呼び出し元の中止要求は、内部で推定したタイムアウトより優先する (§1.4)。
    terminalError = .cancelled
    endOfFileGraceTask?.cancel()
    endOfFileGraceTask = nil
    stopReading()
    stopDirectProcessIfNeeded()
  }

  private func makeProcessResources() throws(ProcessRunnerError) -> ProcessResources {
    let stdout = try makeOutputPipe(label: "awt.process.stdout")
    let stderr: OutputPipe
    do {
      stderr = try makeOutputPipe(label: "awt.process.stderr")
    } catch {
      stdout.reader.stop()
      try? stdout.writeHandle.close()
      throw error
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout.writeHandle
    process.standardError = stderr.writeHandle
    process.terminationHandler = { [weak self] process in
      guard let self else { return }
      let status = process.terminationStatus
      Task {
        await self.processDidTerminate(status: status)
      }
    }
    return ProcessResources(process: process, stdout: stdout, stderr: stderr)
  }

  private func makeOutputPipe(label: String) throws(ProcessRunnerError) -> OutputPipe {
    var descriptors: [Int32] = [0, 0]
    guard Darwin.pipe(&descriptors) == 0 else {
      throw .launchFailed(
        executableURL: executableURL,
        message: "pipe: \(String(cString: Darwin.strerror(errno)))"
      )
    }
    return OutputPipe(
      reader: AsyncPipeReader(
        fileDescriptor: descriptors[0],
        queueLabel: label,
        budget: outputBudget
      ) { [weak self] in
        guard let self else { return }
        Task {
          await self.outputStateChanged()
        }
      },
      writeHandle: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    )
  }

  private func install(_ resources: ProcessResources) {
    process = resources.process
    stdoutReader = resources.stdout.reader
    stderrReader = resources.stderr.reader
  }

  private func closeParentWriteHandles(_ resources: ProcessResources) {
    try? resources.stdout.writeHandle.close()
    try? resources.stderr.writeHandle.close()
  }

  private func startTimeout() {
    timeoutTask = Task { [timeout] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      timeoutReached()
    }
  }

  private func timeoutReached() {
    guard finalResult == nil, terminalError == nil else { return }
    refreshTerminationStatusIfNeeded()
    refreshOutputState()
    handleOutputFailureIfNeeded()
    guard finalResult == nil, terminalError == nil else { return }
    resolveSuccessIfPossible()
    guard finalResult == nil else { return }

    if terminationStatus != nil {
      startEndOfFileGrace()
    } else {
      recordTimeoutAndStop()
    }
  }

  private func startEndOfFileGrace() {
    guard endOfFileGraceTask == nil else { return }
    endOfFileGraceTask = Task {
      do {
        try await Task.sleep(for: Self.endOfFileGracePeriod)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      endOfFileGraceReached()
    }
  }

  private func endOfFileGraceReached() {
    guard finalResult == nil, terminalError == nil else { return }
    refreshTerminationStatusIfNeeded()
    refreshOutputState()
    handleOutputFailureIfNeeded()
    guard finalResult == nil, terminalError == nil else { return }
    resolveSuccessIfPossible()
    guard finalResult == nil else { return }
    recordTimeoutAndStop()
  }

  private func recordTimeoutAndStop() {
    refreshTerminationStatusIfNeeded()
    refreshOutputState()
    terminalError = .timedOut(
      exitCode: terminationStatus,
      stdout: String(decoding: stdoutSnapshot.data, as: UTF8.self),
      stderr: String(decoding: stderrSnapshot.data, as: UTF8.self)
    )
    stopReading()
    stopDirectProcessIfNeeded()
  }

  private func outputStateChanged() {
    guard finalResult == nil else { return }
    refreshOutputState()
    handleOutputFailureIfNeeded()
    guard terminalError == nil else { return }
    resolveSuccessIfPossible()
  }

  private func refreshOutputState() {
    stdoutSnapshot = stdoutReader?.snapshot() ?? .empty
    stderrSnapshot = stderrReader?.snapshot() ?? .empty
  }

  private func handleOutputFailureIfNeeded() {
    guard terminalError == nil else { return }
    let completions = [stdoutSnapshot.completion, stderrSnapshot.completion]
    if completions.contains(.limitExceeded) {
      terminalError = .outputLimitExceeded(limit: outputLimit)
    } else if let errorCode = completions.compactMap({ $0?.errorCode }).first {
      terminalError = .outputReadFailed(
        message: String(cString: Darwin.strerror(errorCode)))
    }
    guard terminalError != nil else { return }
    stopReading()
    stopDirectProcessIfNeeded()
  }

  private func processDidTerminate(status: Int32) {
    terminationStatus = status
    escalationTask?.cancel()
    escalationTask = nil
    refreshOutputState()

    if let terminalError {
      complete(.failure(terminalError))
    } else {
      handleOutputFailureIfNeeded()
      resolveSuccessIfPossible()
    }
  }

  private func resolveSuccessIfPossible() {
    guard terminalError == nil,
      let terminationStatus,
      stdoutSnapshot.completion == .endOfFile,
      stderrSnapshot.completion == .endOfFile
    else { return }

    complete(
      .success(
        ProcessRunResult(
          exitCode: terminationStatus,
          stdout: String(decoding: stdoutSnapshot.data, as: UTF8.self),
          stderr: String(decoding: stderrSnapshot.data, as: UTF8.self)
        )))
  }

  private func stopReading() {
    stdoutReader?.stop()
    stderrReader?.stop()
  }

  private func stopDirectProcessIfNeeded() {
    guard let terminalError else { return }
    guard let process else {
      complete(.failure(terminalError))
      return
    }
    guard processWasLaunched else {
      complete(.failure(terminalError))
      return
    }
    guard process.isRunning else {
      refreshTerminationStatusIfNeeded()
      complete(.failure(terminalError))
      return
    }

    // Foundation.Process が終了・回収できるのは直接起動した PID だけで、孫は残り得る。
    process.terminate()
    guard escalationTask == nil else { return }
    escalationTask = Task {
      do {
        try await Task.sleep(for: Self.terminationGracePeriod)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      escalateTerminationIfNeeded()
    }
  }

  private func escalateTerminationIfNeeded() {
    guard finalResult == nil, terminalError != nil, let process, process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
  }

  private func refreshTerminationStatusIfNeeded() {
    guard terminationStatus == nil, processWasLaunched, let process, !process.isRunning else {
      return
    }
    terminationStatus = process.terminationStatus
  }

  private func waitForResult() async -> Result<ProcessRunResult, ProcessRunnerError> {
    if let finalResult {
      return finalResult
    }
    return await withCheckedContinuation { continuation in
      if let finalResult {
        continuation.resume(returning: finalResult)
      } else {
        resultContinuation = continuation
      }
    }
  }

  private func complete(_ result: Result<ProcessRunResult, ProcessRunnerError>) {
    guard finalResult == nil else { return }
    finalResult = result
    timeoutTask?.cancel()
    timeoutTask = nil
    endOfFileGraceTask?.cancel()
    endOfFileGraceTask = nil
    escalationTask?.cancel()
    escalationTask = nil
    resultContinuation?.resume(returning: result)
    resultContinuation = nil
  }
}
#endif
