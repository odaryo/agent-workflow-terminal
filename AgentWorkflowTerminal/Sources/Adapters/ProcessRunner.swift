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

// 実行ホストは Mac に限定する (設計書 §20.1)。
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
    let stdout: OutputPipe
    let stderr: OutputPipe
  }

  private let executableURL: URL
  private let arguments: [String]
  private let environment: [String: String]
  private let timeout: Duration
  private let outputLimit: Int
  private let outputBudget: OutputBudget

  private var processIdentifier: pid_t?
  private var childWasReaped = false
  private var exitSource: (any DispatchSourceProcess)?
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
      processIdentifier = try spawnChild(resources)
    } catch {
      closeParentWriteHandles(resources)
      let result = Result<ProcessRunResult, ProcessRunnerError>.failure(
        error)
      complete(result)
      stopReading()
      return result
    }
    observeChildExit()
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

    return ProcessResources(stdout: stdout, stderr: stderr)
  }

  private func spawnChild(_ resources: ProcessResources) throws(ProcessRunnerError) -> pid_t {
    try ChildSpawn.launch(
      executableURL: executableURL, arguments: arguments, environment: environment,
      stdout: resources.stdout.writeHandle.fileDescriptor,
      stderr: resources.stderr.writeHandle.fileDescriptor)
  }

  private func observeChildExit() {
    guard let processIdentifier else { return }
    let source = DispatchSource.makeProcessSource(
      identifier: processIdentifier, eventMask: .exit,
      queue: DispatchQueue(label: "awt.process.exit"))
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task {
        await self.childExited()
      }
    }
    exitSource = source
    source.activate()
  }

  private func childExited() async {
    guard processIdentifier != nil else { return }
    refreshTerminationStatusIfNeeded()
    // .exit が回収可能になる直前に届く例が /usr/bin/true の3000回中2回あったため、
    // 一度きりの通知に頼らず、actor を塞がずに回収を待つ (Issue #875)。
    while !childWasReaped {
      do {
        try await Task.sleep(for: .milliseconds(1))
      } catch {
        return
      }
      refreshTerminationStatusIfNeeded()
    }
    guard let terminationStatus else { return }
    processDidTerminate(status: terminationStatus)
  }

  private func makeOutputPipe(label: String) throws(ProcessRunnerError) -> OutputPipe {
    var descriptors: [Int32] = [0, 0]
    guard Darwin.pipe(&descriptors) == 0 else {
      throw .launchFailed(
        executableURL: executableURL,
        message: "pipe: \(String(cString: Darwin.strerror(errno)))"
      )
    }
    for descriptor in descriptors {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
        let errorCode = errno
        descriptors.forEach { _ = Darwin.close($0) }
        throw .launchFailed(
          executableURL: executableURL, message: String(cString: strerror(errorCode)))
      }
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
    refreshTerminationStatusIfNeeded()
    guard let processIdentifier, !childWasReaped else {
      complete(.failure(terminalError))
      return
    }

    // 孫を巻き込まないよう、process group ではなく直接の子だけを停止する。
    _ = Darwin.kill(processIdentifier, SIGTERM)
    guard escalationTask == nil else { return }
    escalationTask = Task {
      do {
        try await Task.sleep(for: Self.terminationGracePeriod)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await escalateTerminationIfNeeded()
    }
  }

  private func escalateTerminationIfNeeded() async {
    guard finalResult == nil, terminalError != nil else { return }
    refreshTerminationStatusIfNeeded()
    guard let processIdentifier, !childWasReaped else {
      await childExited()
      return
    }
    _ = Darwin.kill(processIdentifier, SIGKILL)
  }

  private func refreshTerminationStatusIfNeeded() {
    guard let processIdentifier, !childWasReaped else { return }
    // 回収と kill を同じ actor に閉じ、回収後に再利用された PID への送信を防ぐ。
    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(processIdentifier, &status, WNOHANG)
    } while result == -1 && errno == EINTR
    if result == processIdentifier {
      // Darwin の <sys/wait.h> の WIFEXITED / WEXITSTATUS / WTERMSIG の定義に従う。
      let signal = status & 0x7f
      guard signal != 0x7f else { return }
      terminationStatus = signal == 0 ? (status >> 8) & 0xff : signal
    } else if result == -1 && errno == ECHILD {
      // 他所で回収された子の不明な終了を成功と取り違えない。
      terminationStatus = -1
    } else {
      return
    }
    childWasReaped = true
    exitSource?.cancel()
    exitSource = nil
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
    exitSource?.cancel()
    exitSource = nil
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
