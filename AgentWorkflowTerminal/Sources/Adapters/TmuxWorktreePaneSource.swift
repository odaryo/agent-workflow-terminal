import TerminalCore

public enum TmuxWorktreePaneSourceError: Error, Sendable, Equatable {
  case tmux(TmuxRunnerError)
  case unparsableOutput(failedLineCount: Int)
}

/// 全 worktree の pane 一覧を `list-panes -a` 1回にまとめ、その結果を読み取りの失敗も含めて
/// 短い TTL の間だけ共有する (Issue #239 R3、失敗の共有は #781)。worktree ごとに `-t <session>` で撃つと、外部プロセス起動が worktree 数に
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
  private var latest: CachedListing?
  private var inFlight: InFlightRead?

  /// `capturedAt` は読み始めた時刻で TTL に使い、`listedAt` は読み終えた時刻で
  /// `PaneSnapshot.listedAt` に渡す。
  private struct CachedListing {
    let result: Result<[TmuxPane], TmuxWorktreePaneSourceError>
    let capturedAt: ContinuousClock.Instant
    let listedAt: ContinuousClock.Instant
  }

  /// 起動側と待ち手側で同じ時刻を刻むため、開始時刻を task と一緒に持つ。待ち手が完了時刻を
  /// 使うと、TTL が run にかかった時間ぶん伸びる。
  private struct InFlightRead {
    let task: Task<ReadOutcome, Never>
    let capturedAt: ContinuousClock.Instant
  }

  /// 読み終えた時刻は task の中で1度だけ取る。待ち手がそれぞれ再開後に取ると、合流した
  /// 呼び出しごとに `listedAt` が変わり、同じ一覧の pane が `ps` を共有できなくなる。
  private struct ReadOutcome: Sendable {
    let result: Result<[TmuxPane], TmuxWorktreePaneSourceError>
    let listedAt: ContinuousClock.Instant
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

  /// `listedAt` は、返す pane 一覧を**読み終えた**時刻。TTL 内のキャッシュや読み込み中の結果へ
  /// 合流したときも、その一覧の時刻を返す (呼ばれた時刻ではない)。
  ///
  /// - Important: 読み始めた時刻 (`capturedAt`) を渡さない。tmux が pane の前景を読むのは
  ///   `list-panes` を起動した後なので、読み始めから読み終えまでの間に読み始めた `ps` は、
  ///   tmux が前景として見た Agent を写していないことがある (Issue #553)。
  func listing() async throws(TmuxWorktreePaneSourceError) -> (
    panes: [TmuxPane], listedAt: ContinuousClock.Instant
  ) {
    if let latest, timeSource.now < latest.capturedAt.advanced(by: timeToLive) {
      return (try latest.result.get(), latest.listedAt)
    }
    let read: InFlightRead
    if let inFlight {
      read = inFlight
    } else {
      let capturedAt = timeSource.now
      let task = Task { [runner, timeSource] in
        let result = await Self.read(runner: runner)
        return ReadOutcome(result: result, listedAt: timeSource.now)
      }
      read = InFlightRead(task: task, capturedAt: capturedAt)
      inFlight = read
    }
    let outcome = await read.task.value
    if inFlight?.task == read.task { complete(outcome, capturedAt: read.capturedAt) }
    return (try outcome.result.get(), outcome.listedAt)
  }

  private func complete(_ outcome: ReadOutcome, capturedAt: ContinuousClock.Instant) {
    inFlight = nil
    // 失敗も成功と同じ TTL の間共有する。捨てると、失敗が続く間 session ごとの poll がそれぞれ
    // `list-panes` を起動する。再試行は TTL ぶん遅れるだけで、TTL は pane 一覧周期の半分以下
    // なので、feed が数える「連続2回の失敗」は別々の読み取りのままである。
    latest = CachedListing(
      result: outcome.result, capturedAt: capturedAt, listedAt: outcome.listedAt)
  }

  private static func read(
    runner: TmuxRunner
  ) async -> Result<[TmuxPane], TmuxWorktreePaneSourceError> {
    do {
      // 連携変数 (§12.7) も同じ1回で読む。pane 一覧と別に起動すると外部プロセスが増える。
      let result = try await runner.run(
        arguments: ["list-panes", "-a", "-F", TmuxListPanes.formatWithSummary])
      let parsed = TmuxListPanes.parseWithSummary(output: result.stdout)
      if parsed.panes.isEmpty, !parsed.failures.isEmpty {
        return .failure(.unparsableOutput(failedLineCount: parsed.failures.count))
      }
      return .success(parsed.panes)
    } catch {
      // server ごと居ない場合は「pane が無い」であって障害ではない。`-t` を渡していた頃に
      // 必要だった `can't find window:` の分岐は、`-a` が session を指さないので要らなくなった
      // (session が1つでもある server では、目的の session の不在は「その名前の行が0件」として
      // 現れる。session が0個の server は下の分岐)。socket 欠落も不在へ畳む
      // (Issue #500、Director 決定4、2026-11-02)。attach 済みの client は fd で繋がったままで、
      // 誤った書き込みは bootstrap と Close で止める。観測のたびの lsof 起動コストを避ける。
      if error.isServerAbsent { return .success([]) }
      // server は生きているが session が0個 (`exit-empty off` で起きる) だと、`-a` を付けても
      // tmux は既定の target を解決しようとして解決できず、exit 1 と `no current target\n` を
      // 返す (tmux 3.8 実測。同じ server で `display-message` は成功する。Issue #781)。
      // exit code と stderr の完全一致の両方で絞るのは、それ以外の失敗まで空へ畳むと pane 一覧が
      // 黙って消えるため。`isServerAbsent` に足さないのは、server は生きており、同じ述語を使う
      // 注入や画面読み取りの経路まで不在扱いにしないため。
      if case .commandFailed(exitCode: 1, _, stderr: "no current target\n") = error {
        return .success([])
      }
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
    of session: TerminalSessionKey
  ) async throws(TmuxWorktreePaneSourceError) -> [PaneSnapshot] {
    let listing = try await panes(in: session)
    return listing.panes.map { $0.snapshot(listedAt: listing.listedAt) }
  }

  public func panes(
    of worktree: WorktreeIdentity
  ) async throws(TmuxWorktreePaneSourceError) -> [PaneSnapshot] {
    try await panes(of: .primary(worktree))
  }

  /// `panes(of:)` と同じ共有キャッシュから読むので、両方を呼んでも `list-panes` は増えない。
  public func summaryReadings(
    of session: TerminalSessionKey
  ) async throws(TmuxWorktreePaneSourceError) -> [PaneSummaryReadingsSnapshot] {
    let listing = try await panes(in: session)
    return listing.panes.compactMap { pane in
      pane.summaryReadings.map {
        PaneSummaryReadingsSnapshot(
          pane: pane.snapshot(listedAt: listing.listedAt), readings: $0)
      }
    }
  }

  public func summaryReadings(
    of worktree: WorktreeIdentity
  ) async throws(TmuxWorktreePaneSourceError) -> [PaneSummaryReadingsSnapshot] {
    try await summaryReadings(of: .primary(worktree))
  }

  /// `summaryReadings(of:)` に pane の位置 (`#{window_index}` / `#{pane_index}`) を添えたもの。
  /// 同じ1回の `list-panes` から取るので、概要と位置が別の時点の pane を指すことは無い。
  public func locatedSummaryReadings(
    of session: TerminalSessionKey
  ) async throws(TmuxWorktreePaneSourceError) -> [LocatedPaneSummaryReadings] {
    let listing = try await panes(in: session)
    return listing.panes.compactMap { pane in
      pane.summaryReadings.map {
        LocatedPaneSummaryReadings(
          readings: PaneSummaryReadingsSnapshot(
            pane: pane.snapshot(listedAt: listing.listedAt), readings: $0),
          location: PaneLocation(windowIndex: pane.windowIndex, paneIndex: pane.paneIndex))
      }
    }
  }

  public func locatedSummaryReadings(
    of worktree: WorktreeIdentity
  ) async throws(TmuxWorktreePaneSourceError) -> [LocatedPaneSummaryReadings] {
    try await locatedSummaryReadings(of: .primary(worktree))
  }

  private func panes(
    in session: TerminalSessionKey
  ) async throws(TmuxWorktreePaneSourceError) -> (
    panes: [TmuxPane], listedAt: ContinuousClock.Instant
  ) {
    let name = TmuxSessionName(key: session)
    // `-a` は対象 server の全 session を返すので、ユーザー自身の session の pane が混ざる。
    // 振り分けは String の完全一致だけで行う。前方一致・部分一致・正規化を挟むと、
    // `TmuxSessionName` の生成名と重なる他の session (同じ worktree の `-<n>` 付きを含む)
    // を取り込む。
    let listing = try await paneList.listing()
    return (listing.panes.filter { $0.sessionName == name.rawValue }, listing.listedAt)
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
      // `TmuxRunnerError.isServerAbsent` の1箇所に集め、socket 欠落も同じ不在へ畳む
      // (Issue #500、Director 決定4)。attach 済みの client は fd で繋がったままであり、誤った
      // 書き込みは bootstrap と Close で止めるため、観測のたびに lsof は起動しない。
      if error.isServerAbsent { return nil }
      throw .tmux(error)
    }
  }
}

public struct LocatedPaneSummaryReadings: Sendable, Hashable {
  public let readings: PaneSummaryReadingsSnapshot
  public let location: PaneLocation
}
