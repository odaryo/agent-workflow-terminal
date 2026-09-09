import TerminalCore

public enum TmuxWorktreePaneSourceError: Error, Sendable, Equatable {
  case tmux(TmuxRunnerError)
}

/// 全 worktree の pane 一覧を `list-panes -a` 1回にまとめ、短い TTL の間だけ共有する
/// (Issue #239 R3)。worktree ごとに `-t <session>` で撃つと、外部プロセス起動が worktree 数に
/// 線形に増える。
///
/// - Important: TTL は呼び出し側の pane 一覧の再取得周期の**半分以下**を渡す。周期に近い値だと
///   位相のずれた worktree の poll が畳めないまま、pane 集合の鮮度だけが落ちる。
actor TmuxAllSessionPaneListCache {
  /// 既定の pane 一覧周期 2s の半分。pane 集合の最悪鮮度は 2s + 1s = 3s になる。
  static let defaultTimeToLive = Duration.seconds(1)

  private let runner: TmuxRunner
  private let timeToLive: Duration
  private let timeSource: any ContinuousTimeSource
  private var latest: (panes: [TmuxPane], capturedAt: ContinuousClock.Instant)?
  private var inFlight: InFlightRead?

  /// 起動側と待ち手側で同じ時刻を刻むため、開始時刻を task と一緒に持つ。待ち手が完了時刻を
  /// 使うと、TTL が run にかかった時間ぶん伸びる。
  private struct InFlightRead {
    let task: Task<Result<[TmuxPane], TmuxWorktreePaneSourceError>, Never>
    let capturedAt: ContinuousClock.Instant
  }

  init(
    runner: TmuxRunner,
    timeToLive: Duration = defaultTimeToLive,
    timeSource: any ContinuousTimeSource = SystemContinuousTimeSource()
  ) {
    self.runner = runner
    self.timeToLive = timeToLive
    self.timeSource = timeSource
  }

  func panes() async throws(TmuxWorktreePaneSourceError) -> [TmuxPane] {
    if let latest, timeSource.now < latest.capturedAt.advanced(by: timeToLive) {
      return latest.panes
    }
    if let inFlight {
      let result = await inFlight.task.value
      if self.inFlight?.task == inFlight.task {
        complete(result, capturedAt: inFlight.capturedAt)
      }
      return try result.get()
    }
    let capturedAt = timeSource.now
    let task = Task { [runner] in await Self.read(runner: runner) }
    inFlight = InFlightRead(task: task, capturedAt: capturedAt)
    let result = await task.value
    if inFlight?.task == task { complete(result, capturedAt: capturedAt) }
    return try result.get()
  }

  private func complete(
    _ result: Result<[TmuxPane], TmuxWorktreePaneSourceError>,
    capturedAt: ContinuousClock.Instant
  ) {
    inFlight = nil
    // 失敗はキャッシュしない。次の呼び出しで再試行できるようにする。
    guard case .success(let panes) = result else { return }
    latest = (panes, capturedAt)
  }

  private static func read(
    runner: TmuxRunner
  ) async -> Result<[TmuxPane], TmuxWorktreePaneSourceError> {
    do {
      let result = try await runner.run(
        arguments: ["list-panes", "-a", "-F", TmuxListPanes.format])
      return .success(TmuxListPanes.parse(output: result.stdout).panes)
    } catch {
      // server ごと居ない場合は「pane が無い」であって障害ではない。`-t` を渡していた頃に
      // 必要だった `can't find window:` の分岐は、`-a` が session を指さないので要らなくなった
      // (session 不在は「その名前の行が0件」として現れる)。
      if error.isServerAbsent { return .success([]) }
      return .failure(.tmux(error))
    }
  }
}

public struct TmuxWorktreePaneSource: WorktreePaneSource, Sendable {
  private let runner: TmuxRunner
  private let paneList: TmuxAllSessionPaneListCache

  public init(runner: TmuxRunner) {
    self.init(runner: runner, paneList: TmuxAllSessionPaneListCache(runner: runner))
  }

  init(runner: TmuxRunner, paneList: TmuxAllSessionPaneListCache) {
    self.runner = runner
    self.paneList = paneList
  }

  public func panes(
    of worktree: WorktreeIdentity
  ) async throws(TmuxWorktreePaneSourceError) -> [PaneSnapshot] {
    let session = TmuxSessionName(identity: worktree)
    // `-a` は対象 server の全 session を返すので、ユーザー自身の session の pane が混ざる。
    // 振り分けは String の完全一致だけで行う。前方一致・部分一致・正規化を挟むと、
    // `TmuxSessionName` の生成名と重なる他の session を取り込む。
    return try await paneList.panes()
      .filter { $0.sessionName == session.rawValue }
      .map(\.snapshot)
  }

  /// tmux server の同一性 (`#{pid}`)。`nil` は server が居ない、または値を読めなかったことを
  /// 表し、呼び出し側はこれを「一致した」側へ倒さない (`MainPaneRegistry.resolve`)。
  ///
  /// `list-panes` の format ではなくこの単独コマンドで読むのは、`#{pid}` が pane ではなく
  /// server の属性で、全 pane・全 session に同じ値が並ぶだけだから (実測)。
  ///
  /// - Important: `panes(of:)` と2回に分かれるので、その間に server が入れ替わる窓がある。
  ///   **pane 一覧を読んだ後にこちらを読む**限り、窓に当たったときの組は「古い pane 一覧 +
  ///   新しい server PID」= 不一致になり、登録先が使えないと判断する側へ倒れる。逆向き
  ///   (新しい pane を古い server PID と組にする) はこの順序では起こらない。
  public func serverProcessID() async throws(TmuxWorktreePaneSourceError) -> Int32? {
    do {
      // target を付けない。tmux 3.4 は存在しない session を `-t` に渡しても exit 0 で server の
      // 値を返すため (実測)、target には意味が無く、あると絞り込めるように読めてしまう。
      let result = try await runner.run(arguments: ["display-message", "-p", "#{pid}"])
      return Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
      // server 不在は「同一性を確かめられなかった」であって障害ではない。判定は
      // `TmuxRunnerError.isServerAbsent` の1箇所に集めている (形が2つあるため)。
      if error.isServerAbsent { return nil }
      throw .tmux(error)
    }
  }
}
