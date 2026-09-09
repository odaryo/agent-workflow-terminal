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
  private let processTable: ProcessTableSnapshotCache
  private let screenBatcher: TmuxPaneScreenBatcher
  private var screenChangeTracker = AgentScreenChangeTracker()
  /// pane ごとに、直近で画面変化の追跡へ渡した捕捉時刻。バッチ由来の時刻は同じ pane への
  /// 並行呼び出しが逆順で再開すると戻り得るため、ここで単調にする (戻ると
  /// `secondsSinceScreenChange` が負になる)。
  private var lastScreenObservedAt: [PaneID: ContinuousClock.Instant] = [:]

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
      forgetScreen(of: pane.id)
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
    let secondsSinceScreenChange = screen.flatMap {
      screenChangeTracker.observe(
        screen: $0, paneID: pane.id, at: capturedAt, minimumChangedLines: minimumChangedLines)
    }
    return AgentSignals(
      paneTitle: title, screenText: screen, styledScreenText: styledScreen,
      secondsSinceScreenChange: secondsSinceScreenChange,
      observedAt: captured.snapshot.observedAt
    )
  }

  public func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    guard !pane.isDead else {
      forgetScreen(of: pane.id)
      return .absent
    }
    guard let snapshot = await processTable.snapshot() else { return .undetermined }
    let names = snapshot.processTreeNames(of: pane.processID)
    let liveness =
      names.isDisjoint(with: matchingProcessNames)
      ? AgentLiveness.absent : .alive
    if liveness == .absent { forgetScreen(of: pane.id) }
    return liveness
  }

  public func forget(_ pane: PaneSnapshot) async {
    forgetScreen(of: pane.id)
    await screenBatcher.forget(pane.id)
  }

  private func forgetScreen(of pane: PaneID) {
    screenChangeTracker.forget(paneID: pane)
    lastScreenObservedAt.removeValue(forKey: pane)
  }

  private func monotonicObservationInstant(
    for pane: PaneID, capturedAt: ContinuousClock.Instant
  ) -> ContinuousClock.Instant {
    let instant = lastScreenObservedAt[pane].map { max($0, capturedAt) } ?? capturedAt
    lastScreenObservedAt[pane] = instant
    return instant
  }
}
