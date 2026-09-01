import Darwin
import Dispatch
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

  private enum OutputKind {
    case stdout
    case stderr
  }

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

  private var process: Process?
  private var processWasLaunched = false
  private var stdoutReader: AsyncPipeReader?
  private var stderrReader: AsyncPipeReader?
  private var terminationStatus: Int32?
  private var stdoutData: Data?
  private var stderrData: Data?
  private var terminalError: ProcessRunnerError?
  private var finalResult: Result<ProcessRunResult, ProcessRunnerError>?
  private var resultContinuation:
    CheckedContinuation<Result<ProcessRunResult, ProcessRunnerError>, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var escalationTask: Task<Void, Never>?

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
    observe(resources.stdout.reader, as: .stdout)
    observe(resources.stderr.reader, as: .stderr)

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
      reader: AsyncPipeReader(fileDescriptor: descriptors[0], queueLabel: label),
      writeHandle: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    )
  }

  private func install(_ resources: ProcessResources) {
    process = resources.process
    stdoutReader = resources.stdout.reader
    stderrReader = resources.stderr.reader
  }

  private func observe(_ reader: AsyncPipeReader, as kind: OutputKind) {
    Task { [weak self] in
      let result = await reader.readAll()
      await self?.outputDidComplete(result, as: kind)
    }
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
    resolveSuccessIfPossible()
    guard finalResult == nil else { return }

    terminalError = .timedOut
    stopReading()
    stopDirectProcessIfNeeded()
  }

  private func outputDidComplete(
    _ result: Result<Data, ProcessRunnerError>,
    as kind: OutputKind
  ) {
    guard finalResult == nil else { return }
    switch result {
    case .success(let data):
      switch kind {
      case .stdout: stdoutData = data
      case .stderr: stderrData = data
      }
      resolveSuccessIfPossible()
    case .failure(let error):
      guard terminalError == nil else { return }
      terminalError = error
      stopReading()
      stopDirectProcessIfNeeded()
    }
  }

  private func processDidTerminate(status: Int32) {
    terminationStatus = status
    escalationTask?.cancel()
    escalationTask = nil

    if let terminalError {
      complete(.failure(terminalError))
    } else {
      resolveSuccessIfPossible()
    }
  }

  private func resolveSuccessIfPossible() {
    guard terminalError == nil,
      let terminationStatus,
      let stdoutData,
      let stderrData
    else { return }

    complete(
      .success(
        ProcessRunResult(
          exitCode: terminationStatus,
          stdout: String(decoding: stdoutData, as: UTF8.self),
          stderr: String(decoding: stderrData, as: UTF8.self)
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
    escalationTask?.cancel()
    escalationTask = nil
    resultContinuation?.resume(returning: result)
    resultContinuation = nil
  }
}

private struct AsyncPipeReader: Sendable {
  private struct Event: Sendable {
    let data: Data
    let isDone: Bool
    let errorCode: Int32
  }

  private let channel: DispatchIO
  private let events: AsyncStream<Event>

  init(fileDescriptor: Int32, queueLabel: String) {
    let (events, continuation) = AsyncStream.makeStream(of: Event.self)
    let queue = DispatchQueue(label: queueLabel)
    let channel = DispatchIO(
      type: .stream,
      fileDescriptor: fileDescriptor,
      queue: queue
    ) { errorCode in
      if errorCode != 0 {
        continuation.yield(Event(data: Data(), isDone: true, errorCode: errorCode))
      }
      continuation.finish()
      _ = Darwin.close(fileDescriptor)
    }
    channel.read(offset: 0, length: Int.max, queue: queue) { isDone, data, errorCode in
      continuation.yield(
        Event(
          data: data.map { Data($0) } ?? Data(),
          isDone: isDone,
          errorCode: errorCode
        ))
      if isDone {
        continuation.finish()
      }
    }
    self.channel = channel
    self.events = events
  }

  func readAll() async -> Result<Data, ProcessRunnerError> {
    var output = Data()
    for await event in events {
      output.append(event.data)
      if event.errorCode != 0 {
        return .failure(
          .outputReadFailed(message: String(cString: Darwin.strerror(event.errorCode))))
      }
      if event.isDone {
        return .success(output)
      }
    }
    return .success(output)
  }

  func stop() {
    channel.close(flags: .stop)
  }
}
