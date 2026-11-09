import Darwin
import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("hostctl のローカルsocket §21.4")
struct HostControlSocketTests {
  @Test("実socketで要求と成功・失敗応答を往復する", arguments: [true, false])
  func roundTrip(opened: Bool) async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let expected = HostControlRequest.openWorktree(directory: "/worktree 日本語")
    let response: HostControlResponse =
      opened
      ? .opened(
        HostControlOpenedWorktree(
          session: "awt-x-12345678", directory: "/worktree 日本語", created: true,
          agentCommand: nil))
      : .failure(code: .notRegistered, message: "登録されていません")
    let server = HostControlSocketServer(path: path)
    try await withServer(
      server,
      handler: { request in
        #expect(request == expected)
        return response
      },
      body: {
        let actual = try await HostControlSocketClient.send(
          expected, to: path, timeout: .seconds(30))
        #expect(actual == response)
      }
    )
  }

  @Test("ファイルが無ければserverUnavailableを返す")
  func unavailableWithoutFile() async {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    #expect(!FileManager.default.fileExists(atPath: path))
    do {
      _ = try await HostControlSocketClient.send(
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(30))
      Issue.record("起動していないserverに接続できた")
    } catch {
      #expect(error == .serverUnavailable(path))
    }
  }

  @Test("閉じたsocketの残存ファイルを引き継ぐ")
  func takesOverStaleSocket() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let descriptor = try Self.makeSocket()
    let bound = Self.withAddress(path) { address, length in
      Darwin.bind(descriptor, address, length)
    }
    Darwin.close(descriptor)
    try #require(bound == 0)
    try #require(FileManager.default.fileExists(atPath: path))
    let server = HostControlSocketServer(path: path)
    try await withServer(server) {
      let response = try await HostControlSocketClient.send(
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(30))
      #expect(response == Self.response)
    }
  }

  @Test("生きたserverのsocketを奪わない")
  func rejectsLiveServer() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let first = HostControlSocketServer(path: path)
    let second = HostControlSocketServer(path: path)
    try await withServer(first) {
      do {
        try await second.start { _ in Self.response }
        Issue.record("生きたserverと同じパスで起動できた")
      } catch let error as HostControlSocketError {
        #expect(error == .addressInUse(path))
      }
      await second.stop()
      let response = try await HostControlSocketClient.send(
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(30))
      #expect(response == Self.response)
    }
  }

  @Test("socketを削除されてもlockを保持しstop後に次のserverへ渡す")
  func retainsLockWithoutSocket() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let first = HostControlSocketServer(path: path)
    let second = HostControlSocketServer(path: path)
    try await withServer(first) {
      try FileManager.default.removeItem(atPath: path)
      do {
        try await second.start { _ in Self.response }
        await second.stop()
        Issue.record("socket削除後に生きたserverのlockを奪った")
      } catch let error as HostControlSocketError {
        #expect(error == .addressInUse(path))
      }
    }
    try await withServer(second) {
      let response = try await HostControlSocketClient.send(
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(30))
      #expect(response == Self.response)
    }
    #expect(FileManager.default.fileExists(atPath: path + ".lock"))
  }

  @Test("ぶら下がったsymlinkは消さずioを返す")
  func rejectsDanglingSymlink() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: path + ".missing")
    let server = HostControlSocketServer(path: path)
    do {
      try await server.start { _ in Self.response }
      Issue.record("ぶら下がったsymlinkで起動できた")
    } catch {
      guard case .io = error else {
        Issue.record("io以外のエラー: \(error)")
        return
      }
    }
    await server.stop()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == path + ".missing")
  }

  @Test("lockのsymlinkを辿らずioを返す", arguments: [true, false])
  func rejectsLockSymlink(targetExists: Bool) async throws {
    let path = uniquePath()
    let target = path + ".target"
    let contents = Data("lockのリンク先".utf8)
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
      try? FileManager.default.removeItem(atPath: target)
    }
    if targetExists { try contents.write(to: URL(fileURLWithPath: target)) }
    try FileManager.default.createSymbolicLink(
      atPath: path + ".lock", withDestinationPath: target)
    let server = HostControlSocketServer(path: path)
    do {
      try await server.start { _ in Self.response }
      Issue.record("lockのsymlinkを辿って起動できた")
    } catch {
      switch error {
      case .io: break
      default: Issue.record("io以外のエラー: \(error)")
      }
    }
    await server.stop()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path + ".lock") == target)
    #expect(!FileManager.default.fileExists(atPath: path))
    if targetExists {
      #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == contents)
    } else {
      #expect(!FileManager.default.fileExists(atPath: target))
    }
  }

  @Test("不正UTF-8の要求は置換せずhandlerに渡さずinvalid_requestを返す")
  func rejectsInvalidUTF8Request() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let bytes =
      Array(#"{"version":1,"command":"worktree.open","directory":"/"#.utf8)
      + [0xFF] + Array("\"}\n".utf8)
    try await withServer(
      HostControlSocketServer(path: path),
      handler: { _ in
        Issue.record("不正UTF-8を含む要求がhandlerに渡った")
        return Self.response
      },
      body: {
        let line = try await Self.offPool { try Self.sendRequest(bytes, to: path) }
        let response = try HostControlProtocol.decodeResponse(line).get()
        guard case .failure(let code, _) = response else {
          Issue.record("不正UTF-8の要求が成功した")
          return
        }
        #expect(code == .invalidRequest)
      }
    )
  }

  @Test("キャンセル済みTaskの要求は中断の .io を返す")
  func preservesClientCancellation() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    try await withServer(HostControlSocketServer(path: path)) {
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await HostControlSocketClient.send(
          .openWorktree(directory: "/path"), to: path, timeout: .seconds(30))
      }
      await #expect(throws: HostControlSocketError.io("Hostとの通信が中断されました")) {
        _ = try await task.value
      }
    }
  }

  @Test("invalid_requestのmessageにDecodingErrorを含めない")
  func readableInvalidRequest() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    try await withServer(HostControlSocketServer(path: path)) {
      let line = try await Self.offPool { try Self.sendRequest(Array("{}\n".utf8), to: path) }
      let response = try HostControlProtocol.decodeResponse(line).get()
      guard case .failure(let code, let message) = response else {
        Issue.record("不正要求が成功した")
        return
      }
      #expect(code == .invalidRequest)
      #expect(!message.contains("DecodingError"))
      #expect(message == "要求のJSON形式が不正です")
    }
  }

  @Test("104バイト以上のパスをserverとclientが拒否する", arguments: [104, 105, 200])
  func rejectsLongPath(byteCount: Int) async {
    let path = "/private/tmp/" + String(repeating: "x", count: byteCount - 13)
    #expect(path.utf8.count == byteCount)
    let server = HostControlSocketServer(path: path)
    do {
      try await server.start { _ in Self.response }
      Issue.record("長すぎるパスでserverが起動できた")
    } catch {
      #expect(error == .pathTooLong(path))
    }
    await server.stop()
    do {
      _ = try await HostControlSocketClient.send(
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(30))
      Issue.record("長すぎるパスでclientが接続できた")
    } catch {
      #expect(error == .pathTooLong(path))
    }
  }

  @Test("socketファイルは0600で作る")
  func socketPermissions() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let server = HostControlSocketServer(path: path)
    try await withServer(server) {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(permissions.intValue & 0o777 == 0o600)
      #expect(attributes[.type] as? FileAttributeType == .typeSocket)
    }
  }

  @Test("stopでsocketファイルを削除する")
  func stopRemovesSocket() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let server = HostControlSocketServer(path: path)
    try await withServer(server) {
      #expect(FileManager.default.fileExists(atPath: path))
    }
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test("64KiBを超える要求はhandlerに渡さず接続を閉じる")
  func closesOversizedRequest() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let server = HostControlSocketServer(path: path)
    try await withServer(
      server,
      handler: { _ in
        Issue.record("大きすぎる要求がhandlerに渡った")
        return Self.response
      },
      body: {
        try await Self.offPool {
          try Self.sendOversizedRequest(to: path)
        }
      }
    )
  }

  @Test("遅いhandlerを待ち続けずtimedOutを返す")
  func timesOutSlowHandler() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let server = HostControlSocketServer(path: path)
    try await withServer(
      server,
      handler: { _ in
        try? await Task.sleep(for: .seconds(1))
        return Self.response
      },
      body: {
        do {
          _ = try await HostControlSocketClient.send(
            .openWorktree(directory: "/path"), to: path, timeout: .milliseconds(20))
          Issue.record("期限を超えて応答を待った")
        } catch let error as HostControlSocketError {
          #expect(error == .timedOut)
        } catch {
          Issue.record("想定外のエラー: \(error)")
        }
      }
    )
  }

}

extension HostControlSocketTests {
  @Test("キャンセルに応じないhandlerも期限でfailureを返して接続を閉じる")
  func expiresUncooperativeHandler() async throws {
    let path = uniquePath()
    defer {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".lock")
    }
    let gate = AsyncStream<Void>.makeStream()
    let finished = AsyncStream<Bool>.makeStream()
    defer { gate.continuation.finish() }
    let server = HostControlSocketServer(path: path)
    try await withServer(
      server, handlerTimeout: .milliseconds(20),
      handler: { _ in
        await withCheckedContinuation { continuation in
          Task.detached {
            for await _ in gate.stream {}
            continuation.resume()
          }
        }
        finished.continuation.yield(Task.isCancelled)
        finished.continuation.finish()
        return Self.response
      },
      body: {
        let bytes = Array(
          (HostControlProtocol.encode(.openWorktree(directory: "/path")) + "\n").utf8)
        let line = try await Self.offPool {
          try Self.sendRequest(bytes, to: path, expectClosed: true)
        }
        #expect(
          try HostControlProtocol.decodeResponse(line).get()
            == .failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした"))
        gate.continuation.finish()
        var iterator = finished.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
      })
  }

  @Test("lockの実ファイルの差し替えと削除をinodeで判別する")
  func detectsReplacedLock() throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let descriptor = try SocketIO.lock(path)
    defer { Darwin.close(descriptor) }
    #expect(try SocketIO.isCurrentLock(descriptor, path: path))
    try FileManager.default.removeItem(atPath: path + ".lock")
    #expect(try !SocketIO.isCurrentLock(descriptor, path: path))
    let replacement = try SocketIO.lock(path)
    defer { Darwin.close(replacement) }
    #expect(try !SocketIO.isCurrentLock(descriptor, path: path))
    #expect(try SocketIO.isCurrentLock(replacement, path: path))
  }

  @Test("basenameが8文字で最終パスが103バイトのsocketをbindできる")
  func bindsAtPathLimit() async throws {
    let directory = "/private/tmp/" + UUID().uuidString + String(repeating: "x", count: 45)
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/12345678"
    try #require(path.utf8.count == 103)
    try await withServer(HostControlSocketServer(path: path)) {
      let response = try await HostControlSocketClient.send(
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(2))
      #expect(response == Self.response)
    }
  }
}

extension HostControlSocketTests {
  private static let response = HostControlResponse.opened(
    HostControlOpenedWorktree(
      session: "awt-x-12345678", directory: "/path", created: true, agentCommand: nil))

  private func uniquePath() -> String {
    "/private/tmp/awt-hc-\(UUID().uuidString).sock"
  }

  private func withServer(
    _ server: HostControlSocketServer,
    handlerTimeout: Duration = .seconds(35),
    handler: @escaping @Sendable (HostControlRequest) async -> HostControlResponse = { _ in
      Self.response
    },
    body: () async throws -> Void
  ) async throws {
    do {
      try await server.start(handlerTimeout: handlerTimeout, handler: handler)
      try await body()
      await server.stop()
    } catch {
      await server.stop()
      throw error
    }
  }

  private static func makeSocket() throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    return descriptor
  }

  private static func withAddress(
    _ path: String, body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
  ) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
    }
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  // 同期の recv を並行性ランタイムのスレッドで待つと、コア数の少ない環境でサーバの処理が回らない
  // (CI と LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 で EAGAIN を実測、Issue #700)。
  private static func offPool<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
    }
  }

  private static func sendRequest(
    _ bytes: [UInt8], to path: String, expectClosed: Bool = false
  ) throws -> String {
    let descriptor = try makeSocket()
    defer { Darwin.close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    try #require(
      setsockopt(
        descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0)
    try #require(withAddress(path) { Darwin.connect(descriptor, $0, $1) } == 0)
    let sent = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    try #require(sent == bytes.count)
    var response: [UInt8] = []
    var byte: UInt8 = 0
    while true {
      let received = Darwin.recv(descriptor, &byte, 1, 0)
      try #require(received == 1, "recv=\(received) errno=\(errno) bytes=\(response.count)")
      if byte == 10 {
        if expectClosed { #expect(Darwin.recv(descriptor, &byte, 1, 0) == 0) }
        return String(decoding: response, as: UTF8.self)
      }
      response.append(byte)
    }
  }

  private static func sendOversizedRequest(to path: String) throws {
    let descriptor = try makeSocket()
    defer { Darwin.close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    var noSignal: Int32 = 1
    try #require(
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout<Int32>.size)) == 0)
    try #require(
      setsockopt(
        descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0)
    try #require(
      setsockopt(
        descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0)
    let connected = withAddress(path) { address, length in
      Darwin.connect(descriptor, address, length)
    }
    try #require(connected == 0)
    let line =
      #"{"version":1,"command":"worktree.open","directory":"/"#
      + String(repeating: "x", count: 65_537) + "\"}\n"
    let bytes = Array(line.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { buffer in
        Darwin.send(descriptor, buffer.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      }
      if written < 0 && (errno == EPIPE || errno == ECONNRESET) {
        return
      }
      try #require(written > 0)
      offset += written
    }
    var byte: UInt8 = 0
    let received = Darwin.recv(descriptor, &byte, 1, 0)
    let receiveError = errno
    #expect(received == 0 || (received == -1 && receiveError == ECONNRESET))
  }
  // 回帰テストの追加先が指定されているため、別ファイルへの分割はしない。
  // swiftlint:disable:next file_length
}
