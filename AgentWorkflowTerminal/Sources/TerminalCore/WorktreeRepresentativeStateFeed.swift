import os

/// 実装体はキャンセル時に throw し、過去の期限には即座に戻ること。タイマーの失敗は
/// 出力へ伝播できないため、キャンセル以外で throw すると保持も stream 終了も止まる。
public protocol ContinuousTimeSource: Sendable {
  var now: ContinuousClock.Instant { get }
  func sleep(until deadline: ContinuousClock.Instant) async throws
}

public struct SystemContinuousTimeSource: ContinuousTimeSource {
  private let clock = ContinuousClock()

  public init() {}

  public var now: ContinuousClock.Instant { clock.now }

  public func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await clock.sleep(until: deadline)
  }
}

public struct WorktreeRepresentativeStateFeed: Sendable {
  private let stabilizer: WorktreeRepresentativeStateStabilizer

  public init(
    stabilizer: WorktreeRepresentativeStateStabilizer = WorktreeRepresentativeStateStabilizer()
  ) {
    self.stabilizer = stabilizer
  }

  public func states<Updates>(
    from updates: Updates,
    timeSource: any ContinuousTimeSource = SystemContinuousTimeSource()
  ) -> AsyncStream<WorktreeRepresentativeState?>
  where
    Updates: AsyncSequence & Sendable,
    Updates.Element == [PaneAgentState]
  {
    AsyncStream { continuation in
      let coordinator = FeedCoordinator(
        stabilizer: stabilizer,
        timeSource: timeSource,
        continuation: continuation
      )
      let inputTask = FeedInputTask()
      continuation.onTermination = { _ in
        inputTask.cancel()
        Task { await coordinator.cancel() }
      }
      inputTask.start(
        Task {
          do {
            for try await panes in updates {
              guard !Task.isCancelled else { break }
              await coordinator.receive(panes)
            }
          } catch {
            // `Failure == Never` は macOS 15 以降に限られるため、非 throwing の出力では
            // 入力失敗を正常終了と同じ扱いにする。
          }
          await coordinator.inputFinished(cancelled: Task.isCancelled)
        }
      )
    }
  }
}

private final class FeedInputTask: Sendable {
  private struct State {
    var task: Task<Void, Never>?
    var isCancelled = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func start(_ task: Task<Void, Never>) {
    let shouldCancel = state.withLock { state in
      state.task = task
      return state.isCancelled
    }
    if shouldCancel { task.cancel() }
  }

  func cancel() {
    let task = state.withLock { state in
      state.isCancelled = true
      return state.task
    }
    task?.cancel()
  }
}

private actor FeedCoordinator {
  private let timeSource: any ContinuousTimeSource
  private let continuation: AsyncStream<WorktreeRepresentativeState?>.Continuation
  private var stabilizer: WorktreeRepresentativeStateStabilizer
  private var lastObservedState: WorktreeRepresentativeState?
  private var hasYielded = false
  private var lastYieldedState: WorktreeRepresentativeState?
  private var inputHasFinished = false
  private var timerTask: Task<Void, Never>?
  private var scheduledDeadline: ContinuousClock.Instant?
  private var isCancelled = false

  init(
    stabilizer: WorktreeRepresentativeStateStabilizer,
    timeSource: any ContinuousTimeSource,
    continuation: AsyncStream<WorktreeRepresentativeState?>.Continuation
  ) {
    self.timeSource = timeSource
    self.continuation = continuation
    self.stabilizer = stabilizer
  }

  func receive(_ panes: [PaneAgentState]) {
    guard !isCancelled else { return }
    let observedState = resolveWorktreeRepresentativeState(panes: panes)
    lastObservedState = observedState
    observe(observedState, at: timeSource.now)
    updateTimer()
  }

  func inputFinished(cancelled: Bool) {
    guard !isCancelled else { return }
    if cancelled {
      cancel()
      return
    }
    inputHasFinished = true
    if stabilizer.pendingTransitionDeadline == nil { finish() }
  }

  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    timerTask?.cancel()
    timerTask = nil
    scheduledDeadline = nil
    continuation.finish()
  }

  private func observe(
    _ observedState: WorktreeRepresentativeState?, at instant: ContinuousClock.Instant
  ) {
    let displayedState = stabilizer.observe(state: observedState, at: instant)
    if !hasYielded || displayedState != lastYieldedState {
      continuation.yield(displayedState)
      hasYielded = true
      lastYieldedState = displayedState
    }
  }

  private func updateTimer() {
    let deadline = stabilizer.pendingTransitionDeadline
    if deadline == nil, inputHasFinished {
      finish()
      return
    }
    // 保持の起点をリセットしない設計書 §12.2 の不変条件により、同じ期限は再登録しない。
    guard deadline != scheduledDeadline else { return }
    timerTask?.cancel()
    timerTask = nil
    scheduledDeadline = deadline

    guard let deadline else {
      return
    }

    let timeSource = timeSource
    timerTask = Task {
      do {
        try await timeSource.sleep(until: deadline)
        guard !Task.isCancelled else { return }
        deadlineReached(deadline)
      } catch {}
    }
  }

  private func deadlineReached(_ deadline: ContinuousClock.Instant) {
    guard !isCancelled, scheduledDeadline == deadline else { return }
    timerTask = nil
    scheduledDeadline = nil
    observe(lastObservedState, at: deadline)
    updateTimer()
  }

  private func finish() {
    timerTask?.cancel()
    timerTask = nil
    scheduledDeadline = nil
    continuation.finish()
  }
}
