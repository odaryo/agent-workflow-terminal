import Darwin
import Foundation
import TerminalCore

public enum HostControlSocketError: Error, Sendable, Equatable {
  case pathTooLong(String)
  case addressInUse(String)
  case serverUnavailable(String)
  case timedOut
  case io(String)
}

public actor HostControlSocketServer {
  private let path: String
  private var lockDescriptor: Int32?
  private var stopDescriptor: Int32?
  private var acceptTask: Task<Void, Never>?
  private var connections: [UUID: Task<Void, Never>] = [:]

  public init(path: String) {
    self.path = path
  }

  deinit {
    if let stopDescriptor { Darwin.close(stopDescriptor) }
    acceptTask?.cancel()
    for task in connections.values { task.cancel() }
    if let lockDescriptor {
      Darwin.unlink(path)
      Darwin.close(lockDescriptor)
    }
  }

  public func start(
    handler: @escaping @Sendable (HostControlRequest) async -> HostControlResponse
  ) throws(HostControlSocketError) {
    guard stopDescriptor == nil else { throw .addressInUse(path) }
    _ = try SocketIO.address(path)
    let lock = try SocketIO.lock(path)
    var transferred = false
    defer { if !transferred { Darwin.close(lock) } }
    try SocketIO.removeStaleSocket(path)
    let listener = try SocketIO.makeSocket()
    defer { if !transferred { Darwin.close(listener) } }
    try SocketIO.bindPrivately(listener, path: path)
    let descriptors: [Int32]
    do {
      descriptors = try SocketIO.makeStopPipe()
    } catch {
      Darwin.unlink(path)
      throw error
    }
    let stopRead = descriptors[0]
    let stream = AsyncStream<SocketDescriptor>.makeStream()
    // pollは専用スレッドで待ち、停止pipeのEOFで起こす。fdの所有権はこのスレッドだけへ渡す。
    Thread.detachNewThread {
      SocketIO.acceptConnections(
        listener: listener, stopRead: stopRead, continuation: stream.continuation)
    }
    transferred = true
    lockDescriptor = lock
    stopDescriptor = descriptors[1]
    acceptTask = Task { [weak self] in
      for await descriptor in stream.stream {
        guard !Task.isCancelled, let self else {
          continue
        }
        await self.accept(descriptor, handler: handler)
      }
    }
  }

  public func stop() {
    guard let descriptor = stopDescriptor else { return }
    stopDescriptor = nil
    Darwin.close(descriptor)
    acceptTask?.cancel()
    acceptTask = nil
    for task in connections.values { task.cancel() }
    connections.removeAll()
    Darwin.unlink(path)
    if let lockDescriptor { Darwin.close(lockDescriptor) }
    lockDescriptor = nil
  }

  private func accept(
    _ descriptor: SocketDescriptor,
    handler: @escaping @Sendable (HostControlRequest) async -> HostControlResponse
  ) {
    guard stopDescriptor != nil, !Task.isCancelled else {
      return
    }
    let identifier = UUID()
    let connection = SocketConnection(descriptor: descriptor)
    connections[identifier] = Task { [weak self] in
      await connection.serve(handler: handler)
      await self?.finished(identifier)
    }
  }

  private func finished(_ identifier: UUID) {
    connections.removeValue(forKey: identifier)
  }
}

public enum HostControlSocketClient {
  public static func send(
    _ request: HostControlRequest, to path: String, timeout: Duration
  ) async throws(HostControlSocketError) -> HostControlResponse {
    let address = try SocketIO.address(path)
    let connection = SocketConnection(descriptor: SocketDescriptor(try SocketIO.makeSocket()))
    do {
      return try await withTaskCancellationHandler {
        try await connection.send(request, path: path, address: address, timeout: timeout)
      } onCancel: {
        Task { await connection.close() }
      }
    } catch let error as HostControlSocketError {
      throw error
    } catch {
      throw .io("Hostとの通信が中断されました")
    }
  }
}

private enum SocketIO {
  static func acceptConnections(
    listener: Int32, stopRead: Int32, continuation: AsyncStream<SocketDescriptor>.Continuation
  ) {
    defer {
      Darwin.close(listener)
      Darwin.close(stopRead)
      continuation.finish()
    }
    var events = [
      pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
      pollfd(fd: stopRead, events: Int16(POLLIN), revents: 0),
    ]
    while true {
      let result = Darwin.poll(&events, nfds_t(events.count), -1)
      if result < 0 {
        if errno == EINTR { continue }
        if waitForStop(stopRead, milliseconds: 100) { return }
        continue
      }
      if events[1].revents != 0 { return }
      if events[0].revents & Int16(POLLIN) == 0 {
        if waitForStop(stopRead, milliseconds: 100) { return }
        continue
      }
      let descriptor = Darwin.accept(listener, nil, nil)
      if descriptor < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        if waitForStop(stopRead, milliseconds: 100) { return }
        continue
      }
      continuation.yield(SocketDescriptor(descriptor))
    }
  }

  static func waitForStop(_ descriptor: Int32, milliseconds: Int32) -> Bool {
    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while Darwin.poll(&event, 1, milliseconds) < 0 {
      if errno != EINTR { return false }
    }
    return event.revents != 0
  }

  static func lock(_ path: String) throws(HostControlSocketError) -> Int32 {
    // macOSでは稼働中でもbacklogが満杯ならECONNREFUSEDになるため、接続で生存判定しない。
    let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW
    var descriptor = Darwin.open(path + ".lock", flags, 0o600)
    // 別スレッドが子プロセスを起動している間は、closeしても子が参照を持つのでlockが残る。
    // 実測では子の起動と並行すると約0.3%で起き、1msで解消した。1回の失敗では稼働中と判定しない。
    var retries = 0
    while descriptor < 0, errno == EWOULDBLOCK, retries < 10 {
      usleep(25_000)
      retries += 1
      descriptor = Darwin.open(path + ".lock", flags, 0o600)
    }
    guard descriptor >= 0 else {
      let code = errno
      if code == EWOULDBLOCK { throw .addressInUse(path) }
      throw error(code)
    }
    guard Darwin.fchmod(descriptor, 0o600) == 0 else {
      let failure = error()
      Darwin.close(descriptor)
      throw failure
    }
    return descriptor
  }

  static func error(_ code: Int32 = errno) -> HostControlSocketError {
    .io(String(cString: strerror(code)))
  }

  static func address(_ path: String) throws(HostControlSocketError) -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw .pathTooLong(path)
    }
    guard !path.utf8.contains(0) else { throw .io("socketパスにNULは使えません") }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
    }
    return address
  }

  static func withAddress(
    _ address: sockaddr_un, body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
  ) -> Int32 {
    var address = address
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  static func makeSocket() throws(HostControlSocketError) -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw error() }
    do {
      try configure(descriptor)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  static func makeStopPipe() throws(HostControlSocketError) -> [Int32] {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.pipe(&descriptors) == 0 else { throw error() }
    guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0
    else {
      let failure = error()
      Darwin.close(descriptors[0])
      Darwin.close(descriptors[1])
      throw failure
    }
    return descriptors
  }

  static func configure(_ descriptor: Int32) throws(HostControlSocketError) {
    var noSignal: Int32 = 1
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw error() }
  }

  static func removeStaleSocket(_ path: String) throws(HostControlSocketError) {
    var status = stat()
    guard lstat(path, &status) == 0 else {
      if errno == ENOENT { return }
      throw error()
    }
    guard status.st_mode & S_IFMT == S_IFSOCK else {
      throw .io("socket以外のファイルが存在します: \(path)")
    }
    guard Darwin.unlink(path) == 0 || errno == ENOENT else { throw error() }
  }

  static func bindPrivately(_ descriptor: Int32, path: String) throws(HostControlSocketError) {
    // bind直後のsocketはumask次第で他ユーザーに開くため、0700の中で0600にしてから公開する。
    let parent = path.lastIndex(of: "/").map { String(path[...$0]) } ?? "./"
    var template = Array((parent + "awt-hc-XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { throw error() }
    let directory = String(cString: template)
    defer { Darwin.rmdir(directory) }
    let temporaryPath = directory + "/s"
    defer { Darwin.unlink(temporaryPath) }
    let result = withAddress(try address(temporaryPath)) { Darwin.bind(descriptor, $0, $1) }
    guard result == 0, Darwin.chmod(temporaryPath, 0o600) == 0,
      Darwin.listen(descriptor, 128) == 0
    else { throw error() }
    guard renamex_np(temporaryPath, path, UInt32(RENAME_EXCL)) == 0 else {
      if errno == EEXIST { throw .addressInUse(path) }
      throw error()
    }
  }
}

private final class SocketDescriptor: Sendable {
  let value: Int32

  init(_ value: Int32) {
    self.value = value
  }

  deinit {
    Darwin.close(value)
  }
}

private actor SocketConnection {
  private var descriptor: SocketDescriptor?

  init(descriptor: SocketDescriptor) {
    self.descriptor = descriptor
  }

  func close() {
    descriptor = nil
  }

  func send(
    _ request: HostControlRequest, path: String, address: sockaddr_un, timeout: Duration
  ) async throws -> HostControlResponse {
    defer { close() }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    try await connect(path: path, address: address, deadline: deadline)
    try await writeLine(HostControlProtocol.encode(request), deadline: deadline)
    let bytes = try await readLine(deadline: deadline)
    let line = String(decoding: bytes, as: UTF8.self)
    switch HostControlProtocol.decodeResponse(line) {
    case .success(let response): return response
    case .failure(let error): throw HostControlSocketError.io(error.message)
    }
  }

  private func connect(
    path: String, address: sockaddr_un, deadline: ContinuousClock.Instant
  ) async throws {
    let retryDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
    while true {
      let descriptor = try checkedDescriptor(deadline)
      let result = SocketIO.withAddress(address) { Darwin.connect(descriptor, $0, $1) }
      var code: Int32 = result == 0 ? 0 : errno
      if code == EINPROGRESS || code == EAGAIN {
        code = try await finishConnecting(deadline: deadline)
      }
      if code == 0 { return }
      if code == ENOENT { throw HostControlSocketError.serverUnavailable(path) }
      guard code == ECONNREFUSED else { throw SocketIO.error(code) }
      guard ContinuousClock.now < retryDeadline else {
        throw HostControlSocketError.serverUnavailable(path)
      }
      try await Task.sleep(
        until: min(deadline, min(retryDeadline, .now.advanced(by: .milliseconds(25)))),
        clock: .continuous)
      _ = try checkedDescriptor(deadline)
      guard ContinuousClock.now < retryDeadline else {
        throw HostControlSocketError.serverUnavailable(path)
      }
      self.descriptor = SocketDescriptor(try SocketIO.makeSocket())
    }
  }

  func serve(
    handler: @escaping @Sendable (HostControlRequest) async -> HostControlResponse
  ) async {
    await withTaskCancellationHandler {
      defer { close() }
      do {
        try SocketIO.configure(try checkedDescriptor(.now.advanced(by: .seconds(5))))
        let bytes = try await readLine(deadline: .now.advanced(by: .seconds(5)), limit: 65_536)
        let response: HostControlResponse
        if let line = String(bytes: bytes, encoding: .utf8) {
          switch HostControlProtocol.decodeRequest(line) {
          case .success(let request): response = await handler(request)
          case .failure(let error):
            response = .failure(code: .invalidRequest, message: error.message)
          }
        } else {
          response = .failure(code: .invalidRequest, message: "要求のUTF-8形式が不正です")
        }
        try await writeLine(
          HostControlProtocol.encode(response), deadline: .now.advanced(by: .seconds(5)))
      } catch {
        return
      }
    } onCancel: {
      Task { await self.close() }
    }
  }

  private func checkedDescriptor(_ deadline: ContinuousClock.Instant) throws -> Int32 {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw HostControlSocketError.timedOut }
    guard let descriptor else { throw HostControlSocketError.io("接続は閉じています") }
    return descriptor.value
  }

  private func pause(_ deadline: ContinuousClock.Instant) async throws {
    try await Task.sleep(
      until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(2))), clock: .continuous)
  }

  private func finishConnecting(deadline: ContinuousClock.Instant) async throws -> Int32 {
    while true {
      let descriptor = try checkedDescriptor(deadline)
      var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      let ready = Darwin.poll(&event, 1, 0)
      if ready < 0 && errno != EINTR { throw SocketIO.error() }
      if ready > 0 {
        var code: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else {
          throw SocketIO.error()
        }
        return code
      }
      try await pause(deadline)
    }
  }

  private func readLine(
    deadline: ContinuousClock.Instant, limit: Int = Int.max
  ) async throws -> [UInt8] {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let descriptor = try checkedDescriptor(deadline)
      let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      if count > 0 {
        let chunk = buffer.prefix(count)
        let line = chunk.prefix { $0 != 10 }
        guard line.count <= limit - bytes.count else {
          throw HostControlSocketError.io("要求が64KiBを超えています")
        }
        bytes.append(contentsOf: line)
        if line.count != chunk.count { return bytes }
      } else if count == 0 {
        throw HostControlSocketError.io("改行の前に接続が閉じられました")
      } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        throw SocketIO.error()
      } else {
        try await pause(deadline)
      }
    }
  }

  private func writeLine(_ line: String, deadline: ContinuousClock.Instant) async throws {
    let bytes = Array((line + "\n").utf8)
    var offset = 0
    while offset < bytes.count {
      let descriptor = try checkedDescriptor(deadline)
      let count = bytes.withUnsafeBytes { buffer in
        Darwin.send(descriptor, buffer.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      }
      if count > 0 {
        offset += count
      } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        try await pause(deadline)
      } else {
        throw SocketIO.error()
      }
    }
  }
}
