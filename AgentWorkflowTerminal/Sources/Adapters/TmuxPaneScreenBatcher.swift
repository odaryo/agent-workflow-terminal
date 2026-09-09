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
      case .captured(let entries, let missing, let retry):
        for entry in entries {
          screens[entry.pane] = .captured(entry.screen)
          titles[entry.pane] = entry.title
        }
        if let missing { screens[missing] = .paneNotFound }
        if !retry.isEmpty { pending.insert(retry, at: 0) }
      case .split(let groups):
        pending.insert(contentsOf: groups, at: 0)
      case .unavailable(let pane):
        screens[pane] = .unavailable
      case .fatal(let error):
        return .failure(error)
      }
    }

    for pane in panes where screens[pane] == nil { screens[pane] = .unavailable }
    return .success(
      TmuxPaneScreenSnapshot(
        screens: screens, titles: titles, capturedAt: capturedAt, observedAt: observedAt))
  }

  private enum GroupOutcome {
    /// マーカーが届いた pane の結果と、その次の pane が消えていた場合の再試行。
    case captured([TmuxPaneScreenBatch.Entry], missing: PaneID?, retry: [PaneID])
    case split([[PaneID]])
    /// この pane だけ今回は読めない。他 pane の結果は捨てない。
    case unavailable(PaneID)
    case fatal(TmuxRunnerError)
  }

  private static func resolve(
    outcome: Result<String, TmuxRunnerError>, group: [PaneID], nonce: String
  ) -> GroupOutcome {
    let stdout: String
    switch outcome {
    case .success(let text):
      stdout = text
    case .failure(.process(.outputLimitExceeded)) where group.count > 1:
      let middle = group.count / 2
      return .split([Array(group[..<middle]), Array(group[middle...])])
    case .failure(.process(.outputLimitExceeded)):
      // これ以上分割できない。1 pane の画面だけを諦め、他 pane の結果は残す。
      return .unavailable(group[0])
    case .failure(.commandFailed(_, let text, let stderr))
    where !TmuxRunnerError.isServerAbsent(stderr: stderr):
      // 列は失敗した地点で止まり、そこまでの stdout は残る (tmux 3.4 で実測)。
      stdout = text
    case .failure(let error):
      return .fatal(error)
    }

    // exit code で分岐しない。`display-message` は消えた pane でも exit 0 を返すので、
    // 「マーカーが届いた pane までが完全」という判定だけが両方の失敗を覆う (tmux 3.4 実測)。
    let entries = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: nonce, expected: group)
    guard entries.count < group.count else {
      return .captured(entries, missing: nil, retry: [])
    }
    return .captured(
      entries, missing: group[entries.count],
      retry: Array(group.dropFirst(entries.count + 1)))
  }
}
