import TerminalCore
import Testing

@Suite("surface ライフサイクル状態機械 (Spikes/gate1/README.md 申し送り #6 / #7)")
struct TerminalSurfaceLifecycleTests {

  // MARK: - Helpers

  private static let allEvents: [TerminalSurfaceLifecycleEvent] = [
    .start,
    .creationSucceeded,
    .creationFailed,
    .processExited,
    .restartRequested,
    .retryDeadlineReached(token: 0),
    .retryDeadlineReached(token: 1),
    .retryDeadlineReached(token: 2),
    .environmentMayHaveChanged,
    .shutdown,
  ]

  private func awaitingSurface() -> TerminalSurfaceLifecycle {
    var lifecycle = TerminalSurfaceLifecycle()
    _ = lifecycle.handle(.start)
    return lifecycle
  }

  private func running() -> TerminalSurfaceLifecycle {
    var lifecycle = awaitingSurface()
    _ = lifecycle.handle(.creationSucceeded)
    return lifecycle
  }

  private func exited() -> TerminalSurfaceLifecycle {
    var lifecycle = running()
    _ = lifecycle.handle(.processExited)
    return lifecycle
  }

  private func stopped() -> TerminalSurfaceLifecycle {
    var lifecycle = running()
    _ = lifecycle.handle(.shutdown)
    return lifecycle
  }

  private func scheduledRetry(
    in effects: [TerminalSurfaceLifecycleEffect]
  ) -> (after: Duration, token: Int)? {
    for effect in effects {
      if case .scheduleRetry(let after, let token) = effect { return (after, token) }
    }
    return nil
  }

  /// 生成失敗を `count` 回続け、最後の失敗が出した `scheduleRetry` の間隔を返す。
  private func delaysFromConsecutiveFailures(
    _ count: Int,
    startingFrom lifecycle: TerminalSurfaceLifecycle
  ) throws -> [Duration] {
    var lifecycle = lifecycle
    var delays: [Duration] = []
    for _ in 0..<count {
      let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
      delays.append(retry.after)
      _ = lifecycle.handle(.retryDeadlineReached(token: retry.token))
    }
    return delays
  }

  // MARK: - 遷移表

  @Test("notStarted + start → awaitingSurface / createSurface")
  func startFromNotStarted() {
    var lifecycle = TerminalSurfaceLifecycle()
    #expect(lifecycle.state == .notStarted)
    #expect(lifecycle.handle(.start) == [.createSurface])
    #expect(lifecycle.state == .awaitingSurface)
  }

  @Test("awaitingSurface + creationSucceeded → running / cancelRetry")
  func creationSucceeded() {
    var lifecycle = awaitingSurface()
    #expect(lifecycle.handle(.creationSucceeded) == [.cancelRetry])
    #expect(lifecycle.state == .running)
  }

  @Test("awaitingSurface + creationFailed → awaitingSurface / scheduleRetry")
  func creationFailed() throws {
    var lifecycle = awaitingSurface()
    let effects = lifecycle.handle(.creationFailed)
    let retry = try #require(scheduledRetry(in: effects))
    #expect(effects == [.scheduleRetry(after: retry.after, token: retry.token)])
    #expect(retry.after == .milliseconds(500))
    #expect(lifecycle.state == .awaitingSurface)
  }

  @Test("awaitingSurface + 最新 token の retryDeadlineReached → createSurface")
  func retryDeadlineWithLatestToken() throws {
    var lifecycle = awaitingSurface()
    let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    #expect(lifecycle.handle(.retryDeadlineReached(token: retry.token)) == [.createSurface])
    #expect(lifecycle.state == .awaitingSurface)
  }

  @Test("awaitingSurface + environmentMayHaveChanged → createSurface")
  func environmentMayHaveChangedWhileAwaiting() {
    var lifecycle = awaitingSurface()
    #expect(lifecycle.handle(.environmentMayHaveChanged) == [.createSurface])
    #expect(lifecycle.state == .awaitingSurface)
  }

  @Test("running + processExited → exited / 効果なし")
  func processExitedWhileRunning() {
    var lifecycle = running()
    #expect(lifecycle.handle(.processExited).isEmpty)
    #expect(lifecycle.state == .exited)
  }

  @Test("running + restartRequested → awaitingSurface / cancelRetry, destroySurface, createSurface")
  func restartFromRunning() {
    var lifecycle = running()
    #expect(lifecycle.handle(.restartRequested) == [.cancelRetry, .destroySurface, .createSurface])
    #expect(lifecycle.state == .awaitingSurface)
  }

  @Test("exited + restartRequested → awaitingSurface / cancelRetry, destroySurface, createSurface")
  func restartFromExited() {
    var lifecycle = exited()
    #expect(lifecycle.handle(.restartRequested) == [.cancelRetry, .destroySurface, .createSurface])
    #expect(lifecycle.state == .awaitingSurface)
  }

  @Test("awaitingSurface + restartRequested → destroySurface を出さない")
  func restartFromAwaitingSurface() {
    var lifecycle = awaitingSurface()
    #expect(lifecycle.handle(.restartRequested) == [.cancelRetry, .createSurface])
    #expect(lifecycle.state == .awaitingSurface)
  }

  @Test("running / exited + shutdown → stopped / cancelRetry, destroySurface")
  func shutdownWithLiveSurface() {
    var fromRunning = running()
    #expect(fromRunning.handle(.shutdown) == [.cancelRetry, .destroySurface])
    #expect(fromRunning.state == .stopped)

    var fromExited = exited()
    #expect(fromExited.handle(.shutdown) == [.cancelRetry, .destroySurface])
    #expect(fromExited.state == .stopped)
  }

  @Test("notStarted / awaitingSurface + shutdown → stopped / cancelRetry のみ")
  func shutdownWithoutSurface() {
    var fromNotStarted = TerminalSurfaceLifecycle()
    #expect(fromNotStarted.handle(.shutdown) == [.cancelRetry])
    #expect(fromNotStarted.state == .stopped)

    var fromAwaiting = awaitingSurface()
    #expect(fromAwaiting.handle(.shutdown) == [.cancelRetry])
    #expect(fromAwaiting.state == .stopped)
  }

  @Test("stopped は終端状態", arguments: Self.allEvents)
  func stoppedIsTerminal(event: TerminalSurfaceLifecycleEvent) {
    var lifecycle = stopped()
    #expect(lifecycle.handle(event).isEmpty)
    #expect(lifecycle.state == .stopped)
  }

  @Test(
    "遷移表に無い組み合わせは状態も効果も変えない",
    arguments: [
      (TerminalRendererState.notStarted, TerminalSurfaceLifecycleEvent.creationSucceeded),
      (.notStarted, .creationFailed),
      (.notStarted, .processExited),
      (.notStarted, .restartRequested),
      (.notStarted, .environmentMayHaveChanged),
      (.notStarted, .retryDeadlineReached(token: 1)),
      (.awaitingSurface, .start),
      (.awaitingSurface, .processExited),
      (.running, .start),
      (.running, .creationSucceeded),
      (.running, .creationFailed),
      (.running, .environmentMayHaveChanged),
      (.running, .retryDeadlineReached(token: 1)),
      (.exited, .start),
      (.exited, .creationSucceeded),
      (.exited, .creationFailed),
      (.exited, .processExited),
      (.exited, .environmentMayHaveChanged),
      (.exited, .retryDeadlineReached(token: 1)),
    ]
  )
  func undefinedCombinationsAreInert(
    state: TerminalRendererState,
    event: TerminalSurfaceLifecycleEvent
  ) throws {
    var lifecycle: TerminalSurfaceLifecycle
    switch state {
    case .notStarted: lifecycle = TerminalSurfaceLifecycle()
    case .awaitingSurface: lifecycle = awaitingSurface()
    case .running: lifecycle = running()
    case .exited: lifecycle = exited()
    case .stopped: lifecycle = stopped()
    }
    #expect(lifecycle.handle(event).isEmpty)
    #expect(lifecycle.state == state)
  }

  // MARK: - バックオフ

  @Test("生成失敗が続くと間隔は 500ms から倍々に伸び 30s で頭打ちになる")
  func backoffGrowsAndSaturates() throws {
    let delays = try delaysFromConsecutiveFailures(9, startingFrom: awaitingSurface())
    #expect(
      delays == [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
        .seconds(30), .seconds(30), .seconds(30),
      ])
  }

  @Test("生成成功でカウンタが戻り、次の失敗はまた 500ms から始まる")
  func backoffResetsOnSuccess() throws {
    var lifecycle = awaitingSurface()
    for _ in 0..<4 {
      let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
      _ = lifecycle.handle(.retryDeadlineReached(token: retry.token))
    }
    _ = lifecycle.handle(.creationSucceeded)
    _ = lifecycle.handle(.restartRequested)

    let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    #expect(retry.after == .milliseconds(500))
  }

  @Test("environmentMayHaveChanged を連続で流してもバックオフは戻らない")
  func backoffSurvivesEnvironmentEvents() throws {
    var lifecycle = awaitingSurface()
    var retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    #expect(retry.after == .milliseconds(500))

    for _ in 0..<5 {
      #expect(lifecycle.handle(.environmentMayHaveChanged) == [.createSurface])
    }
    retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    #expect(retry.after == .seconds(1))

    for _ in 0..<5 {
      #expect(lifecycle.handle(.environmentMayHaveChanged) == [.createSurface])
    }
    retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    #expect(retry.after == .seconds(2))
  }

  @Test("restartRequested はバックオフのカウンタを 0 に戻す")
  func restartResetsBackoff() throws {
    var lifecycle = awaitingSurface()
    for _ in 0..<3 {
      let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
      _ = lifecycle.handle(.retryDeadlineReached(token: retry.token))
    }
    _ = lifecycle.handle(.restartRequested)

    let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    #expect(retry.after == .milliseconds(500))
  }

  // MARK: - token

  @Test("古い token の retryDeadlineReached は createSurface を出さない")
  func staleRetryTokenIsIgnored() throws {
    var lifecycle = awaitingSurface()
    let stale = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    _ = lifecycle.handle(.retryDeadlineReached(token: stale.token))
    let latest = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    #expect(latest.token != stale.token)

    #expect(lifecycle.handle(.retryDeadlineReached(token: stale.token)).isEmpty)
    #expect(lifecycle.handle(.retryDeadlineReached(token: latest.token)) == [.createSurface])
  }

  @Test("cancelRetry を出した後は直前の token が無効になる")
  func cancelRetryInvalidatesToken() throws {
    var lifecycle = awaitingSurface()
    let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    _ = lifecycle.handle(.restartRequested)

    #expect(lifecycle.handle(.retryDeadlineReached(token: retry.token)).isEmpty)
  }

  @Test("成功後に停止し損ねたタイマーが発火しても surface を二重生成しない")
  func staleTimerAfterSuccessIsIgnored() throws {
    var lifecycle = awaitingSurface()
    let retry = try #require(scheduledRetry(in: lifecycle.handle(.creationFailed)))
    _ = lifecycle.handle(.creationSucceeded)
    _ = lifecycle.handle(.processExited)
    _ = lifecycle.handle(.restartRequested)

    #expect(lifecycle.handle(.retryDeadlineReached(token: retry.token)).isEmpty)
    #expect(lifecycle.state == .awaitingSurface)
  }

  // MARK: - SurfaceCreationRetryPolicy

  @Test("既定のリトライ間隔は 500ms から倍々で 30s 上限")
  func defaultRetryPolicyDelays() {
    let policy = SurfaceCreationRetryPolicy()
    #expect(policy.delay(forAttempt: 0) == .milliseconds(500))
    #expect(policy.delay(forAttempt: 1) == .seconds(1))
    #expect(policy.delay(forAttempt: 6) == .seconds(30))
    #expect(policy.delay(forAttempt: 1000) == .seconds(30))
  }

  @Test("multiplier が 1 以下でも初期値のまま頭打ちにする")
  func nonGrowingRetryPolicy() {
    let policy = SurfaceCreationRetryPolicy(
      initialDelay: .seconds(2),
      maximumDelay: .seconds(30),
      multiplier: 1
    )
    #expect(policy.delay(forAttempt: 0) == .seconds(2))
    #expect(policy.delay(forAttempt: 1_000_000) == .seconds(2))
  }

  @Test("initialDelay が maximumDelay を超えるときは maximumDelay を返す")
  func initialDelayIsClampedToMaximum() {
    let policy = SurfaceCreationRetryPolicy(
      initialDelay: .seconds(90),
      maximumDelay: .seconds(30),
      multiplier: 2
    )
    #expect(policy.delay(forAttempt: 0) == .seconds(30))
    #expect(policy.delay(forAttempt: 3) == .seconds(30))
  }
}
