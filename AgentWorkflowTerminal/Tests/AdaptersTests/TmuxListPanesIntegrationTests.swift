import Adapters
import Darwin
import Foundation
import Testing

private let isTmuxListPanesIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "tmux session 名の往復統合",
  .enabled(if: isTmuxListPanesIntegrationEnabled)
)
struct TmuxListPanesIntegrationTests {

  @Test("$ の全分岐を parse 後の session target で指定する")
  func roundTripsConditionalDollarEscapesThroughHasSession() async throws {
    let processID = ProcessInfo.processInfo.processIdentifier
    let socketName = "awt-list-panes-round-trip-\(processID)"
    let socketURL = integrationSocketURL(socketName: socketName)
    let prefix = "awt-\(processID)-"
    // 1要素1行に戻すと function_body_length (60行) を3行超えるため、まとめて置く。
    let sessionNames = [
      "letter$a", "under$_", "brace${x}", "digit\\$1", "double$$", "terminal$", "symbol$-",
      "hebrew$א", "japanese$日", "emoji$😀",
      // `\` + `$` + lead byte。0xD7 だけが en_US.UTF-8 で非 alpha になり tmux が `\` を
      // 足さないため、`bshebrew` だけが後続文字クラスによる推測と結果が食い違う。
      "bsletter\\$a", "bshebrew\\$א", "bsemoji\\$😀",
    ].map { prefix + $0 }
    var serverPID: pid_t?
    var serverWasStopped = false
    let executableURL = try #require(
      TmuxRunner.defaultExecutableCandidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    defer {
      if let serverPID {
        serverWasStopped = terminateServer(serverPID)
      }
      removeSocketIfStopped(serverWasStopped, socketURL: socketURL)
    }
    let runner = try TmuxRunner(
      socketName: socketName,
      processRunner: FoundationProcessRunner(),
      executableCandidates: [executableURL]
    )

    var testError: (any Error)?
    do {
      let server = try await runner.run(
        arguments: ["new-session", "-d", "-s", sessionNames[0], "-P", "-F", "#{pid}"])
      serverPID = pid_t(server.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      try #require((serverPID ?? 0) > 0)
      for sessionName in sessionNames.dropFirst() {
        _ = try await runner.run(
          arguments: ["new-session", "-d", "-s", sessionName, "sleep 120"])
      }

      let output = try await runner.run(arguments: ["list-panes", "-a", "-F", TmuxListPanes.format])
      let result = TmuxListPanes.parse(output: output.stdout)

      #expect(result.failures.isEmpty)
      #expect(result.panes.count == sessionNames.count)
      for parsedName in result.panes.map(\.sessionName) {
        _ = try await runner.run(arguments: ["has-session", "-t", parsedName])
      }
    } catch {
      testError = error
    }

    if (try? await runner.run(arguments: ["kill-server"], timeout: .seconds(1))) != nil {
      serverWasStopped = true
      serverPID = nil
    }
    if let testError {
      throw testError
    }
  }

  private func integrationSocketURL(socketName: String) -> URL {
    let socketParent = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/private/tmp"
    return URL(fileURLWithPath: socketParent)
      .appending(path: "tmux-\(getuid())")
      .appending(path: socketName)
  }

  private func removeSocketIfStopped(_ serverWasStopped: Bool, socketURL: URL) {
    guard serverWasStopped else {
      // 生きている server の socket を消すと `-L` から到達不能になるため、停止未確認なら残す。
      FileHandle.standardError.write(
        Data("警告: tmux server を停止できなかったため socket を残します: \(socketURL.path)\n".utf8)
      )
      return
    }
    try? FileManager.default.removeItem(at: socketURL)
  }

  private func terminateServer(_ serverPID: pid_t) -> Bool {
    // 0 以下は kill(2) でプロセスグループ等を指すため、外部出力を syscall へ渡す前に弾く。
    guard serverPID > 0 else { return false }
    guard Darwin.kill(serverPID, SIGTERM) == 0 else { return errno == ESRCH }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(500))
    while clock.now < deadline {
      guard Darwin.kill(serverPID, 0) == 0 else { return errno == ESRCH }
      Darwin.usleep(10_000)
    }
    return Darwin.kill(serverPID, 0) != 0 && errno == ESRCH
  }
}
