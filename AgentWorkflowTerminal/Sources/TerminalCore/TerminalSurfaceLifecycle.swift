/// - Important: `awaitingSurface` は「生成したいが手元に surface が無い」ことだけを表し、
///   未着手・表示面へ未装着・生成失敗後の待機を区別しない。区別が要る情報は上位が別に持つ。
/// - Important: `exited` は surface 内のプロセスだけが終わった状態で、surface 自体は生きている。
///   libghostty が `command` 指定時に `wait-after-command` を強制するため
///   (`TerminalRendererConfiguration.command` 参照)。
public enum TerminalRendererState: Sendable, Hashable {
  case notStarted
  case awaitingSurface
  case running
  case exited
  case stopped
}

public enum TerminalSurfaceLifecycleEvent: Sendable, Hashable {
  case start
  case creationSucceeded
  case creationFailed
  case processExited
  case restartRequested
  /// 実装側がタイマーを止め損ねてもよい。古い `token` は無視される
  /// (`TerminalSurfaceLifecycleEffect.scheduleRetry` 参照)。
  case retryDeadlineReached(token: Int)
  /// アプリ活性化・画面復帰・画面構成変更・表示面への装着をまとめた契機。
  /// ディスプレイスリープ中の生成失敗は正常系であり、これらが再試行の入口になる
  /// (Spikes/gate1/README.md 申し送り #7)。
  case environmentMayHaveChanged
  case shutdown
}

public enum TerminalSurfaceLifecycleEffect: Sendable, Hashable {
  case createSurface
  case destroySurface
  /// `token` は `scheduleRetry` と `cancelRetry` のどちらを出すときも単調増加する。
  /// 停止し損ねたタイマーが `retryDeadlineReached` を届けても、token が古ければ
  /// 無視されるため surface が二重生成されない。実装側のキャンセルに依存しない保証。
  case scheduleRetry(after: Duration, token: Int)
  case cancelRetry
}

/// 時計・タイマー・libghostty を持たない純粋な状態機械。効果の実行は呼び出し側の責務。
///
/// - Important: 再試行間隔のカウンタが 0 に戻るのは `creationSucceeded` と
///   `restartRequested` のときだけ。`environmentMayHaveChanged` による即時再試行では
///   戻さない。画面復帰通知が連続しても再試行間隔が縮まないようにするため。
public struct TerminalSurfaceLifecycle: Sendable {
  public private(set) var state: TerminalRendererState = .notStarted

  private let retry: SurfaceCreationRetryPolicy
  private var failureCount = 0
  private var currentRetryToken = 0

  public init(retry: SurfaceCreationRetryPolicy = SurfaceCreationRetryPolicy()) {
    self.retry = retry
  }

  public mutating func handle(
    _ event: TerminalSurfaceLifecycleEvent
  ) -> [TerminalSurfaceLifecycleEffect] {
    switch state {
    case .notStarted: handleWhileNotStarted(event)
    case .awaitingSurface: handleWhileAwaitingSurface(event)
    case .running: handleWhileRunning(event)
    case .exited: handleWhileExited(event)
    case .stopped: []
    }
  }

  private mutating func handleWhileNotStarted(
    _ event: TerminalSurfaceLifecycleEvent
  ) -> [TerminalSurfaceLifecycleEffect] {
    switch event {
    case .start:
      state = .awaitingSurface
      return [.createSurface]
    case .shutdown:
      return stop(destroyingSurface: false)
    case .creationSucceeded, .creationFailed, .processExited, .restartRequested,
      .retryDeadlineReached, .environmentMayHaveChanged:
      return []
    }
  }

  private mutating func handleWhileAwaitingSurface(
    _ event: TerminalSurfaceLifecycleEvent
  ) -> [TerminalSurfaceLifecycleEffect] {
    switch event {
    case .creationSucceeded:
      state = .running
      failureCount = 0
      return [invalidateRetryToken()]
    case .creationFailed:
      return [scheduleRetry()]
    case .retryDeadlineReached(let token):
      return token == currentRetryToken ? [.createSurface] : []
    case .environmentMayHaveChanged:
      return [.createSurface]
    case .restartRequested:
      failureCount = 0
      return [invalidateRetryToken(), .createSurface]
    case .shutdown:
      return stop(destroyingSurface: false)
    case .start, .processExited:
      return []
    }
  }

  private mutating func handleWhileRunning(
    _ event: TerminalSurfaceLifecycleEvent
  ) -> [TerminalSurfaceLifecycleEffect] {
    switch event {
    case .processExited:
      state = .exited
      return []
    case .restartRequested:
      return restart()
    case .shutdown:
      return stop(destroyingSurface: true)
    case .start, .creationSucceeded, .creationFailed, .retryDeadlineReached,
      .environmentMayHaveChanged:
      return []
    }
  }

  private mutating func handleWhileExited(
    _ event: TerminalSurfaceLifecycleEvent
  ) -> [TerminalSurfaceLifecycleEffect] {
    switch event {
    case .restartRequested:
      return restart()
    case .shutdown:
      return stop(destroyingSurface: true)
    case .start, .creationSucceeded, .creationFailed, .processExited, .retryDeadlineReached,
      .environmentMayHaveChanged:
      return []
    }
  }

  private mutating func restart() -> [TerminalSurfaceLifecycleEffect] {
    state = .awaitingSurface
    failureCount = 0
    return [invalidateRetryToken(), .destroySurface, .createSurface]
  }

  private mutating func stop(
    destroyingSurface: Bool
  ) -> [TerminalSurfaceLifecycleEffect] {
    state = .stopped
    guard destroyingSurface else { return [invalidateRetryToken()] }
    return [invalidateRetryToken(), .destroySurface]
  }

  private mutating func scheduleRetry() -> TerminalSurfaceLifecycleEffect {
    currentRetryToken += 1
    let delay = retry.delay(forAttempt: failureCount)
    failureCount += 1
    return .scheduleRetry(after: delay, token: currentRetryToken)
  }

  private mutating func invalidateRetryToken() -> TerminalSurfaceLifecycleEffect {
    currentRetryToken += 1
    return .cancelRetry
  }
}

public struct SurfaceCreationRetryPolicy: Sendable, Hashable {
  public let initialDelay: Duration
  public let maximumDelay: Duration
  public let multiplier: Int

  public init(
    initialDelay: Duration = .milliseconds(500),
    maximumDelay: Duration = .seconds(30),
    multiplier: Int = 2
  ) {
    self.initialDelay = initialDelay
    self.maximumDelay = maximumDelay
    self.multiplier = multiplier
  }

  /// `attempt` は 0 始まり。試行回数に上限は設けない — ディスプレイスリープ中の生成失敗は
  /// 正常系であり、何時間続いてもよい (Spikes/gate1/README.md 申し送り #7)。
  public func delay(forAttempt attempt: Int) -> Duration {
    var delay = min(initialDelay, maximumDelay)
    guard attempt > 0, multiplier > 1, delay > .zero else { return delay }
    for _ in 0..<attempt {
      delay *= multiplier
      if delay >= maximumDelay { return maximumDelay }
    }
    return delay
  }
}
