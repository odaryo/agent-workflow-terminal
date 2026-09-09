import Foundation
import TerminalCore

enum TmuxPaneScreen: Sendable, Equatable {
  case captured(String)
  /// tmux が pane を見つけられなかった。`capture-pane` の失敗を握り潰していた頃と違い、
  /// 「pane が消えた」と「画面だけ取れなかった」を呼び出し側で区別できるようにする。
  case paneNotFound
  /// 今回のバッチでは取れなかった (起動上限に達した、単独 pane で出力上限を超えた等)。
  /// pane が変わったわけではないので、次のバッチで取り直すだけでよい。
  case unavailable
}

struct TmuxPaneScreenSnapshot: Sendable {
  let screens: [PaneID: TmuxPaneScreen]
  /// `.captured` の pane についてだけ入る。画面と同じマーカーから取るので鮮度は完全に一致する。
  let titles: [PaneID: String]
  /// このバッチを**捕捉した**時刻。キャッシュから読んだ時刻ではないので、画面変化の追跡は
  /// これを使う (キャッシュ時刻を使うと、同じ画面が別時刻で入って鮮度が伸びる)。
  let capturedAt: ContinuousClock.Instant
  let observedAt: Date
}

/// 登録済み pane の画面と title を1プロセスでまとめて取り、短い TTL の間だけ共有する
/// (Issue #239 R2)。pane ごとに `capture-pane` を起動すると、外部プロセス起動が pane 数に
/// 線形に増える。
///
/// - Important: TTL は呼び出し側の `AgentObservationIntervals.signals` の**半分以下**を渡す。
///   これが保証するのは「同じ pane が周期どおりに2回呼ぶと、必ず別のバッチを読む」ことだけで、
///   **サンプル間隔が周期以下に収まることは保証しない**。前回がバッチ捕捉直後、今回が TTL 満了
///   直前だと間隔は最大 `signals + TTL` まで伸び、逆向きには `signals - TTL` まで縮む
///   (既定値では 1.0s〜3.0s)。§7.5 の検出率は 2.0 秒 polling に対する値なので、実効サンプル
///   間隔の分布は別途計測が要る (Issue #239 のレビュー F6)。
actor TmuxPaneScreenBatcher {
  /// 既定の `signals` 周期 2s の半分。
  static let defaultTimeToLive = Duration.seconds(1)

  /// 1起動にまとめる pane の上限。10 pane 規模を1起動で賄えるところで切る。
  static let maximumPanesPerBatch = 16

  /// 1回の捕捉で許す tmux 起動の追加ぶん。pane が消えた時の再バッチと、stdout 上限を超えた
  /// ときの分割がここから引かれ、尽きたら残りは `.unavailable` にして次の周期へ送る
  /// (無限ループ防止)。
  ///
  /// **8 の根拠**: 上限いっぱいの 16 pane グループを二分し続けて 1 pane まで縮めるには
  /// 4 段 (16→8→4→2→1) を要し、各段で失敗する試行が1回ずつ積まれる。それを賄ったうえで、
  /// 同じ捕捉の中で pane が数件消えた場合の再バッチにも余裕を残す値として選んだ。
  /// 完走を保証する値ではない (16 pane を全部 1 pane まで割るには 31 起動が要る) — これは
  /// 「どこで諦めるか」の上限であり、諦めた pane は `.unavailable` として次の周期で取り直す。
  ///
  /// **上振れの条件**: 10 pane なら 1 グループ + 8 = 最大 9 起動/捕捉。捕捉は `signals` 周期
  /// (2s) に 1 回なので最悪 4.5 起動/秒となり、完了条件の「4 回/秒以下」を**原理的には
  /// 超え得る**。到達するには (a) 8 MiB を超える単一 pane が居続ける、または
  /// (b) 8 pane 以上が同じ捕捉の中で消える、のどちらかが要る。(a) は実測 (200×50 の全セル
  /// 色違いで 113,346 バイト) から約 70 倍離れており、(b) は一過性である。実測した定常状態は
  /// 10 pane / 20 秒で 26〜29 起動 = 1.3〜1.5 起動/秒。
  private static let extraLaunchAllowance = 8

  /// `screen(of:)` が1回の呼び出しで起こす refresh の上限。1回目は「自分を含まないバッチが
  /// in-flight だった」場合にそれを待つぶん、2回目が自分を含むバッチになる。
  private static let maximumRefreshRounds = 2

  private let runner: TmuxRunner
  private let timeToLive: Duration
  private let timeSource: any ContinuousTimeSource
  private var registered: [PaneID] = []
  private var latest: TmuxPaneScreenSnapshot?
  private var inFlight: InFlightBatch?

  /// 起動側と待ち手側で同じ時刻を刻むため、開始時刻を task と一緒に持つ。
  private struct InFlightBatch {
    let task: Task<Result<TmuxPaneScreenSnapshot, TmuxRunnerError>, Never>
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

  func forget(_ pane: PaneID) {
    registered.removeAll { $0 == pane }
  }

  /// 呼ばれた pane をバッチ対象へ登録したうえで、その pane の画面を返す。
  func screen(
    of pane: PaneID
  ) async throws(TmuxRunnerError) -> (screen: TmuxPaneScreen, snapshot: TmuxPaneScreenSnapshot) {
    if !registered.contains(pane) { registered.append(pane) }
    var refreshes = 0
    // refresh の**後にも**必ず読み直す。tmux を1回起動して取れた画面を捨てないため。
    while true {
      if let latest, timeSource.now < latest.capturedAt.advanced(by: timeToLive),
        let screen = latest.screens[pane]
      {
        return (screen, latest)
      }
      guard refreshes < Self.maximumRefreshRounds else { break }
      refreshes += 1
      switch await refresh() {
      case .failure(let error): throw error
      case .success: continue
      }
    }
    let snapshot = TmuxPaneScreenSnapshot(
      screens: [:], titles: [:], capturedAt: timeSource.now, observedAt: Date())
    return (.unavailable, snapshot)
  }

  private func refresh() async -> Result<TmuxPaneScreenSnapshot, TmuxRunnerError> {
    if let inFlight {
      let result = await inFlight.task.value
      if self.inFlight?.task == inFlight.task { complete(result) }
      return result
    }
    let panes = registered
    let capturedAt = timeSource.now
    let observedAt = Date()
    let task = Task { [runner] in
      await Self.capture(
        panes: panes, runner: runner, capturedAt: capturedAt, observedAt: observedAt)
    }
    inFlight = InFlightBatch(task: task, capturedAt: capturedAt)
    let result = await task.value
    if inFlight?.task == task { complete(result) }
    return result
  }

  private func complete(_ result: Result<TmuxPaneScreenSnapshot, TmuxRunnerError>) {
    inFlight = nil
    guard case .success(let snapshot) = result else { return }
    latest = snapshot
    for (pane, screen) in snapshot.screens where screen == .paneNotFound {
      registered.removeAll { $0 == pane }
    }
  }

  private static func capture(
    panes: [PaneID], runner: TmuxRunner,
    capturedAt: ContinuousClock.Instant, observedAt: Date
  ) async -> Result<TmuxPaneScreenSnapshot, TmuxRunnerError> {
    var screens: [PaneID: TmuxPaneScreen] = [:]
    var titles: [PaneID: String] = [:]
    var pending = stride(from: 0, to: panes.count, by: maximumPanesPerBatch).map {
      Array(panes[$0..<min($0 + maximumPanesPerBatch, panes.count)])
    }
    var remainingLaunches = pending.count + extraLaunchAllowance

    while !pending.isEmpty, remainingLaunches > 0 {
      let group = pending.removeFirst()
      remainingLaunches -= 1
      let nonce = TmuxPaneScreenBatch.makeNonce()
      let arguments = TmuxPaneScreenBatch.arguments(panes: group, nonce: nonce)
      let outcome: Result<String, TmuxRunnerError>
      do {
        // 上限は**バッチ全体で** `ProcessRunLimits.defaultOutputBytes`。pane 数で割らないのは、
        // 割ると単独 pane の許容量が分割前 (1 pane = 8 MiB) より下がるため。溢れたときは
        // グループを二分して撃ち直すので、1 pane まで縮めば許容量は分割前と完全に一致し、
        // 同時に保持する量も分割前の1回ぶんと同じになる。
        outcome = .success(
          try await runner.run(
            arguments: arguments, outputLimit: ProcessRunLimits.defaultOutputBytes
          ).stdout)
      } catch {
        outcome = .failure(error)
      }

      switch resolve(outcome: outcome, group: group, nonce: nonce) {
      case .captured(let entries, let failed, let retry):
        for entry in entries {
          screens[entry.pane] = .captured(entry.screen)
          titles[entry.pane] = entry.title
        }
        if let failed { screens[failed.pane] = failed.screen }
        if !retry.isEmpty { pending.insert(retry, at: 0) }
      case .split(let groups):
        pending.insert(contentsOf: groups, at: 0)
      case .fatal(let error):
        return .failure(error)
      }
    }

    for pane in panes where screens[pane] == nil { screens[pane] = .unavailable }
    return .success(
      TmuxPaneScreenSnapshot(
        screens: screens, titles: titles, capturedAt: capturedAt, observedAt: observedAt))
  }

  private struct FailedPane {
    let pane: PaneID
    /// `.paneNotFound` (消えた) か `.unavailable` (観測できなかった) のどちらか。
    let screen: TmuxPaneScreen
  }

  private enum GroupOutcome {
    /// マーカーが届いた pane の結果、走査が止まった1件、および残りの再試行。
    case captured([TmuxPaneScreenBatch.Entry], failed: FailedPane?, retry: [PaneID])
    case split([[PaneID]])
    case fatal(TmuxRunnerError)
  }

  private static func resolve(
    outcome: Result<String, TmuxRunnerError>, group: [PaneID], nonce: String
  ) -> GroupOutcome {
    let stdout: String
    let commandFailed: Bool
    switch outcome {
    case .success(let text):
      stdout = text
      commandFailed = false
    case .failure(.process(.outputLimitExceeded)) where group.count > 1:
      let middle = group.count / 2
      return .split([Array(group[..<middle]), Array(group[middle...])])
    case .failure(.process(.outputLimitExceeded)):
      // これ以上分割できない。1 pane の画面だけを諦め、他 pane の結果は残す。
      return .captured([], failed: FailedPane(pane: group[0], screen: .unavailable), retry: [])
    case .failure(.commandFailed(_, let text, let stderr))
    where !TmuxRunnerError.isServerAbsent(stderr: stderr):
      // 列は失敗した地点で止まり、そこまでの stdout は残る (tmux 3.4 で実測)。
      stdout = text
      commandFailed = true
    case .failure(let error):
      return .fatal(error)
    }

    // exit code だけでは分岐できない。`display-message` は消えた pane でも exit 0 を返すため
    // (tmux 3.4 実測)、走査が止まった理由は復号側から取る。
    let output = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: nonce, expected: group)
    guard output.entries.count < group.count else {
      return .captured(output.entries, failed: nil, retry: [])
    }
    let screen: TmuxPaneScreen =
      switch output.stopReason {
      // マーカーの pane ID が空 / 食い違い = pane の消失。
      case .paneIdentityMismatch: .paneNotFound
      // マーカーが届かないまま列が止まるのは `capture-pane` が失敗したとき (= 消えたとき) だけ。
      // exit 0 のまま尽きるのは想定外の形なので、消失側へは倒さない。
      case .truncated: commandFailed ? .paneNotFound : .unavailable
      // pane ID 以外の復号失敗。pane は生きているので登録も変化基準も残す。
      case .malformedMarker, .completed: .unavailable
      }
    return .captured(
      output.entries,
      failed: FailedPane(pane: group[output.entries.count], screen: screen),
      retry: Array(group.dropFirst(output.entries.count + 1)))
  }
}
