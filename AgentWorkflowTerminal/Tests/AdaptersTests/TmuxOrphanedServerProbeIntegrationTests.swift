import Adapters
import Darwin
import Foundation
import TerminalCore
import Testing

@Suite(
  "隔離 tmux server の socket 欠落と lsof probe",
  .enabled(if: ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1")
)
struct TmuxOrphanedServerProbeIntegrationTests {
  @Test("socket を消しても lsof は生きている server の PID を返す")
  func findsServerAfterSocketRemoval() async throws {
    let socketName = uniqueSocketName("orphaned-probe")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/orphaned-probe"))
      let session = TmuxSessionName(identity: identity)
      let operations = TmuxSessionOperations(runner: runner)
      try await operations.create(session: session, workingDirectory: "/private/tmp")
      let pidOutput = try await runner.run(arguments: ["display-message", "-p", "#{pid}"])
      let serverPID = try #require(
        Int32(pidOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
      try #require(serverPID > 0)
      let pathOutput = try await runner.run(arguments: ["display-message", "-p", "#{socket_path}"])
      let socketPath = pathOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      try #require(!socketPath.isEmpty)

      // socket が無いまま body を抜けると withServer の停止処理が server に届かない。
      defer { restoreSocket(serverPID: serverPID, socketPath: socketPath) }
      try FileManager.default.removeItem(atPath: socketPath)
      try #require(!FileManager.default.fileExists(atPath: socketPath))

      await #expect(throws: TmuxSessionOperationError.serverSocketMissing(socketPath: socketPath)) {
        try await operations.exists(session: session)
      }
      let result = await TmuxOrphanedServerProbe().probe(socketPath: socketPath)
      guard case .orphaned(let processIDs) = result else {
        Issue.record("取り残された server を期待したが、\(result) が返った")
        return
      }
      #expect(processIDs.contains(serverPID))
    }
  }

  // 非 ASCII を TMUX_TMPDIR ではなく -L の名前に入れるのは、IsolatedTmuxServer が親プロセスの
  // TMUX_TMPDIR しか使わないため。ファイル名側の非 ASCII も lsof (LC_ALL=C) が `\xe6…` と
  // エスケープすることは実測した (2026-11-02、tmux 3.8、Issue #500)。
  @Test("非 ASCII を含む socket を消すと、生きている server の lsof probe は undetermined")
  func reportsNonASCIISocketPathAsUndetermined() async throws {
    let socketName = uniqueSocketName("orphaned-日本")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let identity = try #require(
        WorktreeIdentity(rawValue: "/repo/.git/worktrees/orphaned-nonascii"))
      let session = TmuxSessionName(identity: identity)
      let operations = TmuxSessionOperations(runner: runner)
      try await operations.create(session: session, workingDirectory: "/private/tmp")
      let pidOutput = try await runner.run(arguments: ["display-message", "-p", "#{pid}"])
      let serverPID = try #require(
        Int32(pidOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
      try #require(serverPID > 0)
      let pathOutput = try await runner.run(arguments: ["display-message", "-p", "#{socket_path}"])
      let socketPath = pathOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      try #require(socketPath.contains("日本"))

      // socket が無いまま body を抜けると withServer の停止処理が server に届かない。
      defer { restoreSocket(serverPID: serverPID, socketPath: socketPath) }
      try FileManager.default.removeItem(atPath: socketPath)
      try #require(!FileManager.default.fileExists(atPath: socketPath))

      // tmux の stderr は生のバイトでパスを出す。lsof (LC_ALL=C) だけが \xe6… とエスケープする。
      await #expect(throws: TmuxSessionOperationError.serverSocketMissing(socketPath: socketPath)) {
        try await operations.exists(session: session)
      }
      let result = await TmuxOrphanedServerProbe().probe(socketPath: socketPath)
      guard case .undetermined = result else {
        Issue.record("server は生きているので absent にしてはならないが、\(result) が返った")
        return
      }
    }
  }

  @Test("一度も起動していない socket の server は absent")
  func reportsNeverStartedSocketAsAbsent() async throws {
    let runner = try TmuxRunner(
      socketName: uniqueSocketName("orphaned-never-started"),
      processRunner: FoundationProcessRunner(),
      executableCandidates: [try #require(IsolatedTmuxServer.executableURL())])
    let result: TmuxSessionOperationError
    do {
      _ = try await TmuxSessionOperations(runner: runner).exists(
        session: TmuxSessionName(
          identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/never-started"))))
      Issue.record("未起動の socket は serverSocketMissing を投げるはず")
      return
    } catch let error as TmuxSessionOperationError {
      result = error
    }
    guard case .serverSocketMissing(let socketPath) = result else {
      Issue.record("socket path を保持するエラーを期待したが、\(result) が返った")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: socketPath))
    #expect(await TmuxOrphanedServerProbe().probe(socketPath: socketPath) == .absent)
  }

  private func restoreSocket(serverPID: Int32, socketPath: String) {
    #expect(Darwin.kill(serverPID, SIGUSR1) == 0)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !FileManager.default.fileExists(atPath: socketPath), ContinuousClock.now < deadline {
      Darwin.usleep(10_000)
    }
    #expect(FileManager.default.fileExists(atPath: socketPath))
  }
}
