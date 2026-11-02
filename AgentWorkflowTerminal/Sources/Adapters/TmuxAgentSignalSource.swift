import Foundation
import TerminalCore

public enum TmuxAgentSignalSourceError: Error, Sendable, Equatable {
  case paneNotFound(PaneID)
  case paneListMalformed([TmuxListPanesParseFailure])
  case tmux(TmuxRunnerError)
  case capture(TmuxCapturePaneError)
}

public enum TmuxCapturePaneError: Error, Sendable, Equatable {
  case invalidPaneID(PaneID)
  case tmux(TmuxRunnerError)
}

public enum TmuxCapturePane {
  static func isWellFormed(_ pane: PaneID) -> Bool {
    pane.rawValue.first == "%" && !pane.rawValue.dropFirst().isEmpty
      && pane.rawValue.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
  }
}

/// pane の軽量信号と process 生存確認を、登録済み pane 全体で共有した外部プロセス起動から
/// 取る (Spikes/gate3/README.md §7.5、§10-2、§11、Issue #239)。
///
/// 画面は SGR / OSC を含む生のまま扱う。文字属性 (dim) が Claude Code の入力欄で
/// プレースホルダと入力済みテキストを分ける唯一の手掛かりであり、plain 側はこれを剥がして
/// 作る (Issue #217)。
///
/// - Note: pane title は画面と同じバッチのマーカーから取る (追加起動 0)。`PaneSnapshot.title`
///   は使えない — `AgentAdapter` の既定 `observations(of:)` は毎周期**同じ snapshot 値**を渡し、
///   `WorktreePaneFeedCoordinator` は `processID` / `currentCommand` / `isDead` が変わらない限り
///   観測 Task を作り直さないので、title が観測開始時刻で凍る。`CodexAdapter` は title の
///   spinner を画面判定より前に短絡するため、凍ると Working から抜けられなくなる。
public actor TmuxAgentSignalSource: AgentSignalSource {
  /// 静か → 変化 の採取で Agent の pid の印を確かめるのは、直前の静かな時間がこれ以上のときだけ
  /// (Issue #560)。確かめたいのは「しばらく待っていた Agent が終わり、次の Agent が描いた」形で、
  /// それより短い間の起動し直しは次の `liveness` (約 6 秒以内) が pid の並びの違いで捕まえる。
  /// 絞らないと、出力が途切れ途切れに出る間は変化のたびに `ps` を読み、`ps` が約 2 倍になる
  /// (`bursty` の 40 秒で 7 → 14 回)。
  ///
  /// 比べるのは「最後の静かな採取の時点の経過」であって、変化の採取までの静かな時間ではない。
  /// 実際に静かだった時間は最大で採取の周期だけ長くなり、製品の周期 (2 秒、
  /// `AgentObservationIntervals.signals`) では実効のしきい値が 5〜7 秒になる。計測では、約 6.3 秒
  /// 静かだったのに最後の静かな採取の経過が 4.32 秒だったため確かめなかった (Issue #566)。
  static let restartCheckMinimumQuietSeconds: TimeInterval = 5

  private let processTable: ProcessTableSnapshotCache
  private let screenBatcher: TmuxPaneScreenBatcher
  private var screenChangeTracker = AgentScreenChangeTracker()
  /// pane ごとに、直近で画面変化の追跡へ渡した捕捉時刻。バッチ由来の時刻は同じ pane への
  /// 並行呼び出しが逆順で再開すると戻り得るため、ここで単調にする (戻ると
  /// `secondsSinceScreenChange` が負になる)。
  private var lastScreenObservedAt: [PaneID: ContinuousClock.Instant] = [:]
  private var screenOwnerProcessIDs: [PaneID: [Set<String>: [Int32]]] = [:]
  private var forgottenAt: [PaneID: ContinuousClock.Instant] = [:]
  /// pane ごとに、直近の `liveness` が `ps` を読めたときの前景。画面の履歴とは別に持ち、
  /// Agent が居なくなっても消さない (消すと、次に起動した Agent を古い `ps` で確かめてしまう)。
  private var livenessForegrounds: [PaneID: PaneForeground] = [:]
  /// pane ごとに、今の画面の基準を作ったときの Agent の pid の印 (Issue #550、設計書 §12.4.2)。
  /// `liveness` の持ち主の記録は前景が変わらない起動し直し (`claude …; claude …`) を次の
  /// `liveness` まで見落とすので、採取の側でも基準とプロセスを結び付ける。
  private var screenBaselines: [PaneID: ScreenBaseline] = [:]
  private var nextScreenBaselineGeneration: UInt64 = 0
  /// 印に使う名前。`liveness` の結果によらず覚える — 名前は呼び出し側が与えるもので、
  /// `ps` の成否とは関係ない。
  private var knownAgentProcessNames: Set<String> = []

  private struct ScreenBaseline {
    /// `ps` を待つ間に基準が作り直されていないかを見分ける。
    let generation: UInt64
    var tag: ProcessTag = .loading
    /// 直前の採取までの静かな時間。出力とみなす変化の採取で 0 に戻す。
    var quietSeconds: TimeInterval = 0
  }

  private enum ProcessTag: Equatable {
    /// 印を付ける `ps` がまだ戻っていない。比べると、同じ Agent でも印が無いことを理由に
    /// 基準を捨ててしまう。
    case loading
    /// 印を付けるときに `ps` を読めなかった。
    case unreadable
    case processIDs([Int32])
  }

  private struct PaneForeground: Equatable {
    let processID: Int32
    let currentCommand: String
    let isDead: Bool

    init(_ pane: PaneSnapshot) {
      self.processID = pane.processID
      self.currentCommand = pane.currentCommand
      self.isDead = pane.isDead
    }
  }

  public init(
    tmuxRunner: TmuxRunner, processRunner: any ProcessRunning,
    processExecutableURL: URL = URL(fileURLWithPath: "/bin/ps")
  ) {
    self.processTable = ProcessTableSnapshotCache(
      processRunner: processRunner, executableURL: processExecutableURL)
    self.screenBatcher = TmuxPaneScreenBatcher(runner: tmuxRunner)
  }

  init(processTable: ProcessTableSnapshotCache, screenBatcher: TmuxPaneScreenBatcher) {
    self.processTable = processTable
    self.screenBatcher = screenBatcher
  }

  public func signals(
    for pane: PaneSnapshot, minimumChangedLines: Int
  ) async throws -> AgentSignals {
    discardExpiredScreenHistory()
    forgottenAt.removeValue(forKey: pane.id)
    guard TmuxCapturePane.isWellFormed(pane.id) else {
      throw TmuxAgentSignalSourceError.capture(.invalidPaneID(pane.id))
    }
    let captured: (screen: TmuxPaneScreen, snapshot: TmuxPaneScreenSnapshot)
    do {
      captured = try await screenBatcher.screen(of: pane.id)
    } catch {
      // tmux 側の失敗は「見に行けなかった」であって pane が変わったわけではないので、
      // 画面変化の基準は保つ (捨てると次の周期まで Unknown が伸びる)。
      throw TmuxAgentSignalSourceError.tmux(error)
    }

    let styledScreen: String?
    let title: String
    switch captured.screen {
    case .paneNotFound:
      forgetPane(pane.id)
      throw TmuxAgentSignalSourceError.paneNotFound(pane.id)
    case .captured(let text):
      // title はマーカーから来るので、画面が取れた pane には必ず付く。欠けているのは想定外の
      // 形なので、空文字を「title が空」として配らず画面ごと取得失敗へ倒す
      // (Codex が Working を取りこぼす向きに黙って倒れるのを避ける)。
      guard let capturedTitle = captured.snapshot.titles[pane.id] else {
        styledScreen = nil
        title = ""
        break
      }
      styledScreen = text
      title = capturedTitle
    case .unavailable:
      // 「今回は見に行かなかった」。pane は生きているので変化追跡の基準は残す。
      styledScreen = nil
      title = ""
    }

    // 画面変化の計測は plain 側で行う。属性だけが変わったフレーム (spinner の色替えなど) を
    // 出力とみなすと `secondsSinceScreenChange` が 0 に張り付く。
    let screen = styledScreen.map { StyledScreenText(capturedWithEscapeSequences: $0).plainText }
    let capturedAt = monotonicObservationInstant(
      for: pane.id, capturedAt: captured.snapshot.capturedAt)
    let screenChange: ScreenChangeObservation?
    if let screen {
      screenChange = await observeScreenChange(
        screen, of: pane, at: capturedAt, screenCapturedAt: captured.snapshot.capturedAt,
        minimumChangedLines: minimumChangedLines)
    } else {
      screenChange = nil
    }
    return AgentSignals(
      paneTitle: title, screenText: screen, styledScreenText: styledScreen,
      secondsSinceScreenChange: screenChange?.secondsSinceChange,
      hasObservedScreenChange: screenChange?.hasObservedChange ?? false,
      observedAt: captured.snapshot.observedAt
    )
  }

  public func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    discardExpiredScreenHistory()
    forgottenAt.removeValue(forKey: pane.id)
    knownAgentProcessNames.formUnion(matchingProcessNames)
    guard !pane.isDead else {
      forgetPane(pane.id)
      return .absent
    }
    // 初めての pane や前景が変わった pane で TTL 内の `ps` を使うと、それが Agent の起動前に
    // 読んだものなら fallback に固定される (Issue #549 / #553)。下限は pane を返した `list-panes`
    // を読み終えた時刻にする — 呼ばれた時刻にすると、同じ一覧の pane ごとに `ps` が走る。
    // 前景が前回の `ps` と同じなら下限を付けない。付けると、pane 一覧を読み直した snapshot で
    // 呼ばれるたびに `ps` が走る。時刻を持たない snapshot は、初めての pane に下限を付けない
    // (起動直後に pane の数だけ `ps` が走る)。
    let foreground = PaneForeground(pane)
    let lowerBound: ContinuousClock.Instant?
    if let previousForeground = livenessForegrounds[pane.id] {
      lowerBound =
        previousForeground == foreground ? nil : pane.listedAt ?? screenBatcher.timeSource.now
    } else {
      lowerBound = pane.listedAt
    }
    let snapshot: ProcessTableSnapshot?
    if let lowerBound {
      snapshot = await processTable.snapshot(capturedNoEarlierThan: lowerBound)
    } else {
      snapshot = await processTable.snapshot()
    }
    // 読めなかったときに記録を進めると、次の呼び出しが TTL 内の古い `ps` を使ってしまう。
    guard let snapshot else { return .undetermined }
    livenessForegrounds[pane.id] = foreground
    let names = snapshot.processTreeNames(of: pane.processID)
    let liveness =
      names.isDisjoint(with: matchingProcessNames)
      ? AgentLiveness.absent : .alive
    // 記録のない名前の集合の absent は、別の種類の Agent 名で引いただけなので消さない。
    // 消すと移動直後の Working を見落とす。記録した Agent が居なくなっても、同じ pane に
    // 記録の残る Agent (claude の子の codex が終わった場合の claude) がいれば画面は
    // そちらのものなので、記録が尽きたときだけ履歴を捨てる (Issue #537 / #546、設計書 §12.4.2)。
    guard liveness == .alive else {
      if screenOwnerProcessIDs[pane.id]?.removeValue(forKey: matchingProcessNames) != nil,
        screenOwnerProcessIDs[pane.id]?.isEmpty ?? true
      {
        forgetScreen(of: pane.id)
      }
      return liveness
    }
    let candidates =
      snapshot.nearestProcessIDs(
        named: matchingProcessNames, inTreeOf: pane.processID
      ).sorted()
    guard !candidates.isEmpty else {
      forgetScreen(of: pane.id)
      return liveness
    }
    if let previous = screenOwnerProcessIDs[pane.id]?[matchingProcessNames], previous != candidates
    {
      forgetScreen(of: pane.id)
    }
    screenOwnerProcessIDs[pane.id, default: [:]][matchingProcessNames] = candidates
    return liveness
  }

  /// §12.7 の「現在の Agent プロセス」。`liveness` と同じ共有 `ps` スナップショットを使うので、
  /// 呼んでも `ps` の起動は増えない。`matchingProcessNames` には fallback adapter と同じ
  /// Agent 名の集合を渡す。
  public func agentProcess(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> PaneAgentProcess {
    // dead pane の `pane_pid` は終了済みで、再利用されて無関係な木を指し得る。
    guard !pane.isDead else { return .notRunning }
    guard let snapshot = await processTable.snapshot() else { return .unobservable }
    let candidates = snapshot.nearestProcessIDs(
      named: matchingProcessNames, inTreeOf: pane.processID)
    switch candidates.count {
    case 0: return .notRunning
    case 1: return .identified(processID: candidates[0])
    default: return .ambiguous(processIDs: candidates)
    }
  }

  public func forget(_ pane: PaneSnapshot) async {
    discardExpiredScreenHistory()
    // 移動元の後始末で即座に消すと、同じプロセスでも移動直後の Working を見落とす。
    // 引き継ぎ猶予の間は履歴を残す (Issue #537 / #546、設計書 §12.4.2)。ちょうど猶予の時刻に
    // 戻った pane は引き継ぐ。通知の引き継ぎの猶予 (`PaneNotificationPlanner.isWithinHandoffGrace`)
    // は、ちょうど 10 秒を外と扱う。守るものが違うので、揃えない。
    forgottenAt[pane.id] = screenBatcher.timeSource.now
    await screenBatcher.forget(pane.id)
  }

  /// 印を確かめるのは、しばらく静かだった状態から変わった採取 (ターンの始まり) だけにする。
  /// 毎回確かめると `ps` の頻度が採取の周期と同じになり、生存確認と状態観測を分けた理由
  /// (`ps` のコスト) に反する (設計書 §12.4.2)。
  ///
  /// - Note: 次の3つは閉じない。Agent が画面を変え続けている最中に起動し直した場合、
  ///   最後の静かな採取の経過が `restartCheckMinimumQuietSeconds` に届かないうちに起動し直した
  ///   場合 (どちらも次の `liveness` が捕まえる)、画面の捕捉から `ps` の読み込みまでの間 (数 ms) に
  ///   起動し直した場合。2つ目の窓は、実際に静かだった時間では最大で採取の周期だけ広く、製品の
  ///   周期 (2 秒) では 5〜7 秒静かでも確かめないことがある (計測: 約 6.3 秒静かでも、最後の
  ///   静かな採取が 4.32 秒で確かめなかった。Issue #566)。
  private func observeScreenChange(
    _ screen: String, of pane: PaneSnapshot, at observedAt: ContinuousClock.Instant,
    screenCapturedAt: ContinuousClock.Instant, minimumChangedLines: Int
  ) async -> ScreenChangeObservation? {
    let observation = screenChangeTracker.observeChange(
      screen: screen, paneID: pane.id, at: observedAt, minimumChangedLines: minimumChangedLines)
    guard let observation else {
      let generation = beginScreenBaseline(of: pane.id)
      let processIDs = await agentProcessIDs(of: pane, capturedNoEarlierThan: screenCapturedAt)
      if screenBaselines[pane.id]?.generation == generation {
        screenBaselines[pane.id]?.tag = processIDs.map(ProcessTag.processIDs) ?? .unreadable
      }
      return nil
    }
    guard observation.isOutput else {
      screenBaselines[pane.id]?.quietSeconds = observation.secondsSinceChange
      return observation
    }
    guard let baseline = screenBaselines[pane.id] else { return observation }
    screenBaselines[pane.id]?.quietSeconds = 0
    guard baseline.quietSeconds >= Self.restartCheckMinimumQuietSeconds, baseline.tag != .loading
    else { return observation }
    let processIDs = await agentProcessIDs(of: pane, capturedNoEarlierThan: screenCapturedAt)
    // 待つ前の写しと比べない。待つ間に基準が作り直されていれば、それは今回の比較対象ではない。
    guard let current = screenBaselines[pane.id], current.generation == baseline.generation
    else { return observation }
    // 読めなかったときは捨てない。捨てると、`ps` が失敗している間のターンの始まりが
    // すべて Unknown に落ちる。
    guard let processIDs, current.tag != .processIDs(processIDs) else { return observation }
    forgetScreen(of: pane.id)
    let rebasedAt = monotonicObservationInstant(for: pane.id, capturedAt: observedAt)
    _ = screenChangeTracker.observeChange(
      screen: screen, paneID: pane.id, at: rebasedAt, minimumChangedLines: minimumChangedLines)
    _ = beginScreenBaseline(of: pane.id)
    screenBaselines[pane.id]?.tag = .processIDs(processIDs)
    return nil
  }

  private func beginScreenBaseline(of pane: PaneID) -> UInt64 {
    nextScreenBaselineGeneration &+= 1
    screenBaselines[pane] = ScreenBaseline(generation: nextScreenBaselineGeneration)
    return nextScreenBaselineGeneration
  }

  private func agentProcessIDs(
    of pane: PaneSnapshot, capturedNoEarlierThan lowerBound: ContinuousClock.Instant
  ) async -> [Int32]? {
    // 名前が無ければ木の中身によらず空なので、`ps` を読まない。
    guard !knownAgentProcessNames.isEmpty else { return [] }
    // dead pane の `pane_pid` は再利用されて無関係な木を指し得る。
    guard !pane.isDead,
      let snapshot = await processTable.snapshot(capturedNoEarlierThan: lowerBound)
    else { return nil }
    return snapshot.nearestProcessIDs(named: knownAgentProcessNames, inTreeOf: pane.processID)
      .sorted()
  }

  private func discardExpiredScreenHistory() {
    let now = screenBatcher.timeSource.now
    for (pane, instant) in forgottenAt
    where now > instant.advanced(by: PaneNotificationPlanner.paneHandoffGrace) {
      forgetPane(pane)
    }
  }

  private func forgetPane(_ pane: PaneID) {
    forgetScreen(of: pane)
    livenessForegrounds.removeValue(forKey: pane)
  }

  private func forgetScreen(of pane: PaneID) {
    screenChangeTracker.forget(paneID: pane)
    lastScreenObservedAt.removeValue(forKey: pane)
    screenOwnerProcessIDs.removeValue(forKey: pane)
    screenBaselines.removeValue(forKey: pane)
    forgottenAt.removeValue(forKey: pane)
  }

  private func monotonicObservationInstant(
    for pane: PaneID, capturedAt: ContinuousClock.Instant
  ) -> ContinuousClock.Instant {
    let instant = lastScreenObservedAt[pane].map { max($0, capturedAt) } ?? capturedAt
    lastScreenObservedAt[pane] = instant
    return instant
  }
}
