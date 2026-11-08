import Adapters
import Darwin
import Foundation
import TerminalCore
import Testing

@Suite("hostctl のローカルsocket §21.4")
struct HostControlSocketTests {
  @Test("実socketで要求と成功・失敗応答を往復する", arguments: [true, false])
  func roundTrip(opened: Bool) async throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
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
          expected, to: path, timeout: .seconds(2))
        #expect(actual == response)
      }
    )
  }

  @Test("ファイルが無ければserverUnavailableを返す")
  func unavailableWithoutFile() async {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(!FileManager.default.fileExists(atPath: path))
    do {
      _ = try await HostControlSocketClient.send(
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(2))
      Issue.record("起動していないserverに接続できた")
    } catch {
      #expect(error == .serverUnavailable(path))
    }
  }

  @Test("閉じたsocketの残存ファイルを引き継ぐ")
  func takesOverStaleSocket() async throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
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
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(2))
      #expect(response == Self.response)
    }
  }

  @Test("生きたserverのsocketを奪わない")
  func rejectsLiveServer() async throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
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
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(2))
      #expect(response == Self.response)
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
        .openWorktree(directory: "/path"), to: path, timeout: .seconds(2))
      Issue.record("長すぎるパスでclientが接続できた")
    } catch {
      #expect(error == .pathTooLong(path))
    }
  }

  @Test("socketファイルは0600で作る")
  func socketPermissions() async throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
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
    defer { try? FileManager.default.removeItem(atPath: path) }
    let server = HostControlSocketServer(path: path)
    try await withServer(server) {
      #expect(FileManager.default.fileExists(atPath: path))
    }
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test("64KiBを超える要求はhandlerに渡さず接続を閉じる")
  func closesOversizedRequest() async throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let server = HostControlSocketServer(path: path)
    try await withServer(
      server,
      handler: { _ in
        Issue.record("大きすぎる要求がhandlerに渡った")
        return Self.response
      },
      body: {
        try await Task.detached {
          try Self.sendOversizedRequest(to: path)
        }.value
      }
    )
  }

  @Test("遅いhandlerを待ち続けずtimedOutを返す")
  func timesOutSlowHandler() async throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
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

  private static let response = HostControlResponse.opened(
    HostControlOpenedWorktree(
      session: "awt-x-12345678", directory: "/path", created: true, agentCommand: nil))

  private func uniquePath() -> String {
    "/private/tmp/awt-hc-\(UUID().uuidString).sock"
  }

  private func withServer(
    _ server: HostControlSocketServer,
    handler: @escaping @Sendable (HostControlRequest) async -> HostControlResponse = { _ in
      Self.response
    },
    body: () async throws -> Void
  ) async throws {
    do {
      try await server.start(handler: handler)
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
}
