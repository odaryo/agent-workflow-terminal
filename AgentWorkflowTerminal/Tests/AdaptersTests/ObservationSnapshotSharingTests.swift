import Foundation
import TerminalCore
import Testing
import os

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

private func waitForLaunches(_ expectedLaunches: Int, runner: GateProcessRunner) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(30))
  while true {
    let launches = await runner.launches
    if launches >= expectedLaunches { return }
    if clock.now >= deadline {
      Issue.record("1回目の要求が runner に届かなかった: launches = \(launches)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// `async let` で始めた呼び出しが actor へ届くまでの猶予。届かないまま release すると
/// 起動が2回になってテストが落ちるので、見逃す方向へは倒れない。
/// 2回目の要求が cache の in-flight に合流したことは直接観測できないため、この猶予を残す。
/// 待ちが足りなければ起動が2回になって落ち、見逃しにはならない (#470)。
///
/// `Task.yield()` の空回しで待たないのは、協調スレッドを占有して同じプロセスで並行に走る
/// 他 suite の待ち合わせを飢えさせるため (実測: それで `WorktreePaneAgentStateFeedTests` が
/// 10 回に 1 回落ちた)。`Task.sleep` はスレッドを手放す。
private func waitForArrival() async throws {
  try await Task.sleep(for: .milliseconds(50))
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
    try await waitForLaunches(1, runner: runner)
    #expect(await runner.launches == 1)
    async let second = cache.snapshot()
    try await waitForArrival()
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

  @Test("p1: TTL 内でも鮮度の下限より古い ps は取り直す")
  func processTableRefreshesSnapshotBeforeLowerBound() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let cache = ProcessTableSnapshotCache(
      processRunner: spy, executableURL: URL(fileURLWithPath: "/ps"), timeSource: clock)
    let first = try #require(await cache.snapshot())
    #expect(first.processTreeNames(of: 70) == ["zsh"])
    #expect(await spy.count(of: .ps) == 1)

    await spy.setProcessTableOutput("70 1 /bin/zsh\n71 70 claude\n")
    clock.advance(by: .seconds(1))
    let refreshed = try #require(await cache.snapshot(capturedNoEarlierThan: clock.now))

    #expect(refreshed.processTreeNames(of: 70) == ["zsh", "claude"])
    #expect(await spy.count(of: .ps) == 2)
  }

  @Test("p2: 下限以後に読んだ ps は TTL 内なら共有する", arguments: [0, 1])
  func processTableReusesSnapshotAtOrAfterLowerBound(secondsBeforeCapture: Int) async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 claude\n")
    let clock = ManualTimeSource()
    let lowerBound = clock.now
    clock.advance(by: .seconds(secondsBeforeCapture))
    let cache = ProcessTableSnapshotCache(
      processRunner: spy, executableURL: URL(fileURLWithPath: "/ps"), timeSource: clock)
    _ = try #require(await cache.snapshot())
    await spy.setProcessTableOutput("70 1 codex\n")
    clock.advance(by: .seconds(1))

    let reused = try #require(await cache.snapshot(capturedNoEarlierThan: lowerBound))

    #expect(reused.processTreeNames(of: 70) == ["claude"])
    #expect(await spy.count(of: .ps) == 1)
  }

  @Test("p3: 下限より古い in-flight を待たずに読み、遅れた古い結果で上書きしない")
  func processTableKeepsNewerSnapshotWhenOlderReadFinishesLast() async throws {
    let runner = FreshnessGateProcessRunner()
    let clock = ManualTimeSource()
    let cache = ProcessTableSnapshotCache(
      processRunner: runner, executableURL: URL(fileURLWithPath: "/ps"), timeSource: clock)
    async let oldRead = cache.snapshot()
    let firstStarted = await runner.waitForLaunches(1)
    #expect(firstStarted)
    clock.advance(by: .seconds(1))
    async let newRead = cache.snapshot(capturedNoEarlierThan: clock.now)
    let secondStarted = await runner.waitForLaunches(2)
    #expect(secondStarted)
    // 古い要求に合流する実装でも、失敗を報告した後に待ち手を残さない。
    if !secondStarted { await runner.releaseFirstRead() }
    let newer = await newRead
    #expect(newer?.processTreeNames(of: 70) == ["codex"])
    await runner.releaseFirstRead()
    let older = await oldRead
    #expect(older?.processTreeNames(of: 70) == ["claude"])

    let latest = try #require(await cache.snapshot())
    #expect(latest.processTreeNames(of: 70) == ["codex"])
    #expect(await runner.launches == 2)
  }

  @Test("p4: 下限とちょうど同じ時刻に読み始めた in-flight の ps には合流する")
  func processTableJoinsInFlightReadStartedAtLowerBound() async throws {
    let runner = GateProcessRunner(
      result: ProcessRunResult(exitCode: 0, stdout: "70 1 claude\n", stderr: ""))
    let clock = ManualTimeSource()
    let cache = ProcessTableSnapshotCache(
      processRunner: runner, executableURL: URL(fileURLWithPath: "/ps"),
      timeToLive: .zero, timeSource: clock)
    let startedAt = clock.now

    async let first = cache.snapshot()
    try await waitForLaunches(1, runner: runner)
    async let second = cache.snapshot(capturedNoEarlierThan: startedAt)
    try await waitForArrival()
    await runner.release()
    let names = await [first?.processTreeNames(of: 70), second?.processTreeNames(of: 70)]

    #expect(await runner.launches == 1)
    #expect(names == [["claude"], ["claude"]])
  }

  @Test("p6: 置き去りにした古い ps が後で終わっても、新しい in-flight への合流先は外れない")
  func processTableKeepsNewerInFlightWhenOlderReadFinishes() async throws {
    let runner = PerLaunchGateProcessRunner()
    let clock = ManualTimeSource()
    let cache = ProcessTableSnapshotCache(
      processRunner: runner, executableURL: URL(fileURLWithPath: "/ps"), timeSource: clock)
    async let oldRead = cache.snapshot()
    #expect(await runner.waitForLaunches(1))
    clock.advance(by: .seconds(1))
    let lowerBound = clock.now
    async let newRead = cache.snapshot(capturedNoEarlierThan: lowerBound)
    #expect(await runner.waitForLaunches(2))
    await runner.release(launch: 1)
    _ = await oldRead

    async let joined = cache.snapshot(capturedNoEarlierThan: lowerBound)
    try await waitForArrival()
    let launchesWhileNewerReadIsInFlight = await runner.launches
    await runner.releaseAll()
    let names = await [newRead?.processTreeNames(of: 70), joined?.processTreeNames(of: 70)]

    #expect(launchesWhileNewerReadIsInFlight == 2)
    #expect(names == [["agent2"], ["agent2"]])
  }

  @Test("同時に来た pane 一覧の要求は1回の list-panes を共有する")
  func paneListCoalescesConcurrentRequests() async throws {
    let runner = GateProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    let cache = TmuxAllSessionPaneListCache(
      runner: try makeTmuxRunner(socketName: "share-test", processRunner: runner),
      timeToLive: .zero, timeSource: ManualTimeSource())

    async let first = cache.listing()
    try await waitForLaunches(1, runner: runner)
    #expect(await runner.launches == 1)
    async let second = cache.listing()
    try await waitForArrival()
    await runner.release()
    _ = try await (first, second)

    #expect(await runner.launches == 1)
  }

  @Test("y7: in-flight の pane 一覧に合流した呼び出しは、最初の呼び出しと同じ listedAt を受け取る")
  func paneListWaitersShareListedAt() async throws {
    let runner = GateProcessRunner(result: ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    let cache = TmuxAllSessionPaneListCache(
      runner: try makeTmuxRunner(socketName: "share-test", processRunner: runner),
      timeToLive: .zero, timeSource: TickingTimeSource())

    async let first = cache.listing()
    try await waitForLaunches(1, runner: runner)
    async let second = cache.listing()
    try await waitForArrival()
    await runner.release()
    let (firstListing, secondListing) = try await (first, second)

    #expect(await runner.launches == 1)
    #expect(firstListing.listedAt == secondListing.listedAt)
  }

  @Test("list-panes の失敗はキャッシュせず次の呼び出しで取り直す")
  func paneListDoesNotCacheFailure() async throws {
    let spy = ObservationProcessSpy(
      listPanesFailure: ProcessRunResult(exitCode: 1, stdout: "", stderr: "boom\n"))
    let cache = TmuxAllSessionPaneListCache(
      runner: try makeTmuxRunner(socketName: "share-test", processRunner: spy),
      timeToLive: .seconds(10), timeSource: ManualTimeSource())

    for _ in 0..<2 {
      await #expect(throws: TmuxWorktreePaneSourceError.self) { try await cache.listing() }
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

private actor FreshnessGateProcessRunner: ProcessRunning {
  private(set) var launches = 0
  private var firstRead: CheckedContinuation<Void, Never>?
  private var isFirstReadReleased = false

  func releaseFirstRead() {
    isFirstReadReleased = true
    firstRead?.resume()
    firstRead = nil
  }

  func waitForLaunches(_ count: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while launches < count {
      guard clock.now < deadline else { return false }
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch { return false }
    }
    return true
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    launches += 1
    let isFirstRead = launches == 1
    if isFirstRead && !isFirstReadReleased {
      await withCheckedContinuation { firstRead = $0 }
    }
    return ProcessRunResult(
      exitCode: 0, stdout: isFirstRead ? "70 1 claude\n" : "70 1 codex\n", stderr: "")
  }
}

/// 起動ごとに個別に止め、番号を指定して返させる `ProcessRunning`。2つの読み込みを並行させたまま
/// 古い方だけを終わらせないと、終わった古い読み込みが in-flight を外すかを主張できない。
/// n 回目の起動は `70 1 agent<n>` の1行を返す。
private actor PerLaunchGateProcessRunner: ProcessRunning {
  private(set) var launches = 0
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private var released: Set<Int> = []
  private var isAllReleased = false

  func release(launch: Int) {
    released.insert(launch)
    waiters.removeValue(forKey: launch)?.resume()
  }

  /// 失敗した変異でも待ち手を残さないよう、後から来る起動も止めない。
  func releaseAll() {
    isAllReleased = true
    for waiter in waiters.values { waiter.resume() }
    waiters.removeAll()
  }

  func waitForLaunches(_ count: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while launches < count {
      guard clock.now < deadline else { return false }
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch { return false }
    }
    return true
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    launches += 1
    let launch = launches
    if !isAllReleased && !released.contains(launch) {
      await withCheckedContinuation { waiters[launch] = $0 }
    }
    return ProcessRunResult(exitCode: 0, stdout: "70 1 agent\(launch)\n", stderr: "")
  }
}

/// `now` を読むたびに 1ms 進む `ContinuousTimeSource`。合流した待ち手がそれぞれ時刻を読むと、
/// テストの側で時計を進める隙が無くても値がずれるようにする。
private struct TickingTimeSource: ContinuousTimeSource {
  private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock().now)

  var now: ContinuousClock.Instant {
    instant.withLock {
      $0 = $0.advanced(by: .milliseconds(1))
      return $0
    }
  }

  func sleep(until deadline: ContinuousClock.Instant) async throws {}
}
