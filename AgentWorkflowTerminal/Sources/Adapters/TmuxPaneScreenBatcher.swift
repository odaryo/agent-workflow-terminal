import Foundation
import TerminalCore

enum TmuxPaneScreen: Sendable, Equatable {
  case captured(String)
  /// tmux が pane を見つけられなかった。`capture-pane` の失敗を握り潰していた頃と違い、
  /// 「pane が消えた」と「画面だけ取れなかった」を呼び出し側で区別できるようにする。
  case paneNotFound
  /// 今回のバッチでは取れなかった (起動上限に達した等)。次のバッチで取り直す。
  case unavailable
}

struct TmuxPaneScreenSnapshot: Sendable {
  let screens: [PaneID: TmuxPaneScreen]
  /// このバッチを**捕捉した**時刻。キャッシュから読んだ時刻ではないので、画面変化の追跡は
  /// これを使う (キャッシュ時刻を使うと、同じ画面が別時刻で入って鮮度が伸びる)。
  let capturedAt: ContinuousClock.Instant
  let observedAt: Date
}

/// 登録済み pane の画面を1プロセスでまとめて取り、短い TTL の間だけ共有する
/// (Issue #239 R2)。pane ごとに `capture-pane` を起動すると、外部プロセス起動が pane 数に
/// 線形に増える。
///
/// - Important: TTL は呼び出し側の `AgentObservationIntervals.signals` の**半分以下**を渡す。
///   同じ pane が周期 `signals` で2回呼ぶとき、1回目に配ったバッチの捕捉時刻 c は
///   `c ≦ t₁` かつ `t₁ < c + TTL` を満たすので、`TTL ≦ signals/2` なら
///   `c + TTL ≦ t₁ + signals/2 < t₁ + signals ≦ t₂` となり、2回目は必ず別のバッチを読む。
///   これが §7.5 の「1 pane あたりの実効 polling 間隔を 2.0 秒より粗くしない」条件。
actor TmuxPaneScreenBatcher {
  /// 既定の `signals` 周期 2s の半分。
  static let defaultTimeToLive = Duration.seconds(1)

  /// 1起動にまとめる pane の上限。10 pane 規模を1起動で賄いつつ、`outputBytesPerPane` を
  /// 掛けた stdout 上限が現実的な値に収まるところで切る。
  static let maximumPanesPerBatch = 16

  /// 1 pane あたりの stdout 取り分。全セルの色が違う 200x50 の pane の
  /// `capture-pane -e -p` が 113,346 バイトだったので (tmux 3.4 で実測) 約9倍の余裕がある。
  /// バッチ全体の上限は `pane 数 × この値` で、16 pane でも 16 MiB。分割前は1 pane ごとに
  /// `ProcessRunLimits.defaultOutputBytes` (8 MiB) を許していたので、総量は減っている。
  static let outputBytesPerPane = 1_024 * 1_024

  /// 1回の捕捉で許す tmux 起動の追加ぶん。pane が消えた時の再バッチと、stdout 上限を超えた
  /// ときの分割がここから引かれ、尽きたら残りは `.unavailable` にして次の周期へ送る
  /// (無限ループ防止)。
  private static let extraLaunchAllowance = 4

  private let runner: TmuxRunner
  private let timeToLive: Duration
  private let timeSource: any ContinuousTimeSource
  private var registered: [PaneID] = []
  private var latest: TmuxPaneScreenSnapshot?
  private var inFlight: Task<Result<TmuxPaneScreenSnapshot, TmuxRunnerError>, Never>?

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
    // 2回で足りる: 1回目に in-flight のバッチ (この pane の登録より前に始まったかもしれない)
    // を待ち、2回目で必ず自分を含む新しいバッチを起こす。
    for _ in 0..<2 {
      if let latest, timeSource.now < latest.capturedAt.advanced(by: timeToLive),
        let screen = latest.screens[pane]
      {
        return (screen, latest)
      }
      switch await refresh() {
      case .failure(let error): throw error
      case .success: continue
      }
    }
    let snapshot = TmuxPaneScreenSnapshot(
      screens: [:], capturedAt: timeSource.now, observedAt: Date())
    return (.unavailable, snapshot)
  }

  private func refresh() async -> Result<TmuxPaneScreenSnapshot, TmuxRunnerError> {
    if let task = inFlight {
      let result = await task.value
      if inFlight == task { complete(result) }
      return result
    }
    let panes = registered
    let capturedAt = timeSource.now
    let observedAt = Date()
    let task = Task { [runner] in
      await Self.capture(
        panes: panes, runner: runner, capturedAt: capturedAt, observedAt: observedAt)
    }
    inFlight = task
    let result = await task.value
    if inFlight == task { complete(result) }
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
        outcome = .success(
          try await runner.run(
            arguments: arguments, outputLimit: group.count * outputBytesPerPane
          ).stdout)
      } catch {
        outcome = .failure(error)
      }

      switch resolve(outcome: outcome, group: group, nonce: nonce) {
      case .captured(let entries, let missing, let retry):
        for entry in entries { screens[entry.pane] = .captured(entry.screen) }
        if let missing { screens[missing] = .paneNotFound }
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
        screens: screens, capturedAt: capturedAt, observedAt: observedAt))
  }

  private enum GroupOutcome {
    case captured(
      [(pane: PaneID, screen: String)], missing: PaneID?, retry: [PaneID])
    case split([[PaneID]])
    case fatal(TmuxRunnerError)
  }

  private static func resolve(
    outcome: Result<String, TmuxRunnerError>, group: [PaneID], nonce: String
  ) -> GroupOutcome {
    switch outcome {
    case .success(let stdout):
      return .captured(
        TmuxPaneScreenBatch.parse(stdout: stdout, nonce: nonce, expected: group),
        missing: nil, retry: [])
    case .failure(.process(.outputLimitExceeded)) where group.count > 1:
      let middle = group.count / 2
      return .split([Array(group[..<middle]), Array(group[middle...])])
    case .failure(.commandFailed(_, let stdout, let stderr))
    where !TmuxRunnerError.isServerAbsent(stderr: stderr):
      // 列は失敗した地点で止まり、そこまでの stdout は残る (tmux 3.4 で実測)。
      // マーカーを付けられなかった先頭の pane が、消えた pane。
      let completed = TmuxPaneScreenBatch.parse(stdout: stdout, nonce: nonce, expected: group)
      guard completed.count < group.count else {
        return .captured(completed, missing: nil, retry: [])
      }
      return .captured(
        completed, missing: group[completed.count],
        retry: Array(group.dropFirst(completed.count + 1)))
    case .failure(let error):
      return .fatal(error)
    }
  }
}
