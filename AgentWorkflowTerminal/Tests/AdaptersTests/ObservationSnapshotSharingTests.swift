import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 応答を止められる `ProcessRunning`。in-flight の畳み込みは「同時に到着した2つの呼び出しが
/// 1回の起動を共有する」ことなので、1回目を止めたまま2回目を入れないと主張できない。
private actor GateProcessRunner: ProcessRunning {
  private(set) var launches = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var isBlocking = true
  private let result: ProcessRunResult

  init(result: ProcessRunResult) { self.result = result }

  func release() {
    isBlocking = false
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    launches += 1
    if isBlocking {
      await withCheckedContinuation { waiters.append($0) }
    }
    return result
  }
}

/// `async let` で始めた呼び出しが actor へ届くまでの猶予。届かないまま release すると
/// 起動が2回になってテストが落ちるので、通らない方向へ倒れる。
private func yieldRepeatedly() async {
  for _ in 0..<500 { await Task.yield() }
}

@Suite("観測スナップショットの共有")
struct ObservationSnapshotSharingTests {
  @Test("同時に来た ps 要求は1回の起動を共有する")
  func processTableCoalescesConcurrentRequests() async throws {
    let runner = GateProcessRunner(
      result: ProcessRunResult(exitCode: 0, stdout: "70 1 /opt/agent\n", stderr: ""))
    // TTL を 0 にして、畳み込めた理由がキャッシュではないことを確かめる。
    let cache = ProcessTableSnapshotCache(
      processRunner: runner, executableURL: URL(fileURLWithPath: "/ps"),
      timeToLive: .zero, timeSource: ManualTimeSource())

    async let first = cache.snapshot()
    await yieldRepeatedly()
    #expect(await runner.launches == 1)
    async let second = cache.snapshot()
    await yieldRepeatedly()
    await runner.release()
    let names = await [first?.processTreeNames(of: 70), second?.processTreeNames(of: 70)]

    #expect(await runner.launches == 1)
    #expect(names == [["agent"], ["agent"]])
  }

  @Test("TTL の内側は起動せず、越えたら取り直す")
  func processTableHonorsTimeToLive() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /opt/agent\n")
    let clock = ManualTimeSource()
    let cache = ProcessTableSnapshotCache(
      processRunner: spy, executableURL: URL(fileURLWithPath: "/ps"),
      timeToLive: .milliseconds(2_500), timeSource: clock)

    _ = await cache.snapshot()
    clock.advance(by: .seconds(2))
    _ = await cache.snapshot()
    #expect(await spy.count(of: .ps) == 1)

    clock.advance(by: .seconds(1))
    _ = await cache.snapshot()
    #expect(await spy.count(of: .ps) == 2)
  }

  @Test("ps の失敗はキャッシュせず次の呼び出しで取り直す")
  func processTableDoesNotCacheFailure() async throws {
    let spy = FailingProcessRunner()
    let clock = ManualTimeSource()
    let cache = ProcessTableSnapshotCache(
      processRunner: spy, executableURL: URL(fileURLWithPath: "/ps"),
      timeToLive: .seconds(10), timeSource: clock)

    #expect(await cache.snapshot() == nil)
    #expect(await cache.snapshot() == nil)
    #expect(await spy.launches == 2)
  }

  @Test("同時に来た pane 一覧の要求は1回の list-panes を共有する")
  func paneListCoalescesConcurrentRequests() async throws {
    let runner = GateProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    let cache = TmuxAllSessionPaneListCache(
      runner: try makeTmuxRunner(socketName: "share-test", processRunner: runner),
      timeToLive: .zero, timeSource: ManualTimeSource())

    async let first: [TmuxPane] = cache.panes()
    await yieldRepeatedly()
    #expect(await runner.launches == 1)
    async let second: [TmuxPane] = cache.panes()
    await yieldRepeatedly()
    await runner.release()
    _ = try await [first, second]

    #expect(await runner.launches == 1)
  }

  @Test("list-panes の失敗はキャッシュせず次の呼び出しで取り直す")
  func paneListDoesNotCacheFailure() async throws {
    let spy = ObservationProcessSpy(
      listPanesFailure: ProcessRunResult(exitCode: 1, stdout: "", stderr: "boom\n"))
    let cache = TmuxAllSessionPaneListCache(
      runner: try makeTmuxRunner(socketName: "share-test", processRunner: spy),
      timeToLive: .seconds(10), timeSource: ManualTimeSource())

    for _ in 0..<2 {
      await #expect(throws: TmuxWorktreePaneSourceError.self) { try await cache.panes() }
    }
    #expect(await spy.count(of: .listPanes) == 2)
  }
}

private actor FailingProcessRunner: ProcessRunning {
  private(set) var launches = 0

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    launches += 1
    throw .cancelled
  }
}
