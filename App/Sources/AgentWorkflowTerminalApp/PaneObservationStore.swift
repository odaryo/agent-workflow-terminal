import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// Project 1件 (`AppModel`) の pane 観測を worktree ごとに1本だけ回し、その結果を配る (Issue #189)。
///
/// タブの代表状態、Drawer の送信可否、Overview (設計書 §13) はどれもここを読む。view が観測を
/// 起こすと、view の無い worktree (非選択の Project、描画されていないタブ) が観測されず、view が
/// 2つあれば同じ worktree を二重に観測する。
///
/// - Important: 観測してよい worktree の判定は `WorktreeInventory.observesPaneStates(of:)` だけに
///   任せる (Inactive を観測しない、Issue #237)。
@MainActor
final class PaneObservationStore: ObservableObject {
  struct Observed: Equatable {
    /// 生の観測。`nil` はまだ1度も届いていないこと (空配列 = Agent pane が無い、と区別する)。
    var paneStates: [PaneAgentState]?
    /// Overview に出す、pane ごとに安定化した状態 (§12.2 と同じ保持)。
    var displayStates: [PaneDisplayState] = []
    /// 非 Agent pane の分も含む。
    var details: [PaneID: OverviewPaneDetail] = [:]
    /// `#{pane_pid}`。メイン pane の登録 (`MainPaneRegistration`) が今もその pane を指すかの照合に
    /// 使う — `%N` だけで照合すると、server の再起動で振り直された別の pane に印が付く。
    var processIDs: [PaneID: Int32] = [:]
  }

  @Published private(set) var observed: [WorktreeIdentity: Observed] = [:]
  /// 値に意味は無く、変わったことが「メイン window の端末へフォーカスを戻せ」を表す。
  @Published private(set) var terminalFocusRequest = 0

  /// `nil` は tmux を使えない起動。
  private let feed: WorktreePaneStatesFeed?
  private let paneSource: TmuxWorktreePaneSource?
  private let signalSource: TmuxAgentSignalSource?
  private let purposeWriter: TmuxPanePurposeWriter?
  private let paneOperations: TmuxPaneOperations?
  /// `nil` は通知を出さない起動 (bundle の外、設計書 §11.2)。
  private let notifier: PaneNotifier?

  private var observations: [WorktreeIdentity: Observation] = [:]
  private var subscribers: [WorktreeIdentity: [UUID: AsyncStream<[PaneAgentState]>.Continuation]] =
    [:]
  private var stabilizers: [WorktreeIdentity: PaneDisplayStateStabilizer] = [:]
  private var completions = PaneTaskCompletionTracker()
  private var completionEntries: [PaneID: PaneSummaryEntry<AgentStampedValue>] = [:]
  private var isStopped = false
  private let clock = ContinuousClock()

  /// 概要 (§12.7) を読み直す間隔。pane 一覧の feed と同じ 2 秒にする。`list-panes` は feed と
  /// 同じキャッシュ (TTL 1 秒) から読むので、外部プロセスの起動は TTL で上から抑えられる。
  private static let summaryInterval = Duration.seconds(2)

  private struct Observation {
    let states: Task<Void, Never>
    let summaries: Task<Void, Never>
    var deadline: Task<Void, Never>?

    func cancel() {
      states.cancel()
      summaries.cancel()
      deadline?.cancel()
    }
  }

  init(dependencies: AppDependencies, notifier: PaneNotifier?) {
    self.notifier = notifier
    feed = dependencies.paneStates
    paneSource = dependencies.paneSource
    signalSource = dependencies.signalSource
    purposeWriter = dependencies.tmuxRunner.map(TmuxPanePurposeWriter.init(runner:))
    paneOperations = dependencies.tmuxRunner.map(TmuxPaneOperations.init(runner:))
  }

  /// `inventory` が変わるたびに呼ぶ。観測の対象を揃え、外れた worktree の観測は止める。
  func observe(_ inventory: WorktreeInventory) {
    guard !isStopped, feed != nil else { return }
    var targets: [DetectedWorktree] = []
    if let projectRoot = inventory.projectRoot,
      inventory.observesPaneStates(of: projectRoot.identity)
    {
      targets.append(projectRoot)
    }
    targets += inventory.taskWorktrees.map(\.detected).filter {
      inventory.observesPaneStates(of: $0.identity)
    }
    // feed が使うのは identity だけなので、branch などが変わっても観測し直さない。し直すと
    // 安定化の保持と最終更新が初期化され、Overview の並びが動く。
    let wanted = Set(targets.map(\.identity))
    for identity in observations.keys where !wanted.contains(identity) {
      stop(identity)
    }
    for worktree in targets where observations[worktree.identity] == nil {
      start(worktree)
    }
  }

  /// 登録解除した Project の観測を止める。以後 `observe(_:)` は何もしない。
  func stopAll() {
    isStopped = true
    for identity in Array(observations.keys) {
      stop(identity)
    }
  }

  /// 生の pane 状態の購読。呼んでも観測は増えない。最新の値があれば最初にそれを流す。
  /// `nil` は tmux を使えない起動。
  func paneStates(of identity: WorktreeIdentity) -> AsyncStream<[PaneAgentState]>? {
    guard feed != nil else { return nil }
    let token = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      guard observations[identity] != nil else {
        continuation.finish()
        return
      }
      subscribers[identity, default: [:]][token] = continuation
      if let current = observed[identity]?.paneStates {
        continuation.yield(current)
      }
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.subscribers[identity]?[token] = nil }
      }
    }
  }

  func requestTerminalFocus() {
    terminalFocusRequest &+= 1
  }

  /// その pane の window を current window にし、pane を active にする (§13 の行の選択)。
  func reveal(_ pane: PaneID) async -> TmuxPaneOperationError? {
    guard let paneOperations else { return nil }
    do {
      try await paneOperations.selectWindowAndPane(pane: pane)
      return nil
    } catch {
      return error
    }
  }

  /// 空 (空白だけ) は削除 (`TmuxPanePurposeWriter.setPurpose`)。
  func setPurpose(_ text: String, of pane: PaneID) async -> TmuxPanePurposeWriterError? {
    guard let purposeWriter else { return nil }
    do {
      try await purposeWriter.setPurpose(text, of: pane)
      return nil
    } catch {
      return error
    }
  }

  // MARK: - 観測

  private func start(_ worktree: DetectedWorktree) {
    guard let feed else { return }
    let identity = worktree.identity
    let states = Task { [weak self] in
      for await snapshot in feed(worktree) {
        guard !Task.isCancelled else { return }
        self?.receive(snapshot, for: identity)
      }
    }
    let summaries = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshSummaries(of: identity)
        try? await Task.sleep(for: Self.summaryInterval)
      }
    }
    observations[identity] = Observation(states: states, summaries: summaries)
    observed[identity] = Observed()
    notifier?.observationStarted(identity)
  }

  private func stop(_ identity: WorktreeIdentity) {
    observations.removeValue(forKey: identity)?.cancel()
    notifier?.observationStopped(identity)
    for continuation in subscribers.removeValue(forKey: identity)?.values ?? [:].values {
      continuation.finish()
    }
    stabilizers[identity] = nil
    if let gone = observed.removeValue(forKey: identity) {
      for paneID in gone.details.keys {
        completions.forget(paneID: paneID)
        completionEntries[paneID] = nil
      }
    }
  }

  private func receive(_ snapshot: WorktreePaneAgentStates, for identity: WorktreeIdentity) {
    let panes = snapshot.panes
    guard var current = observed[identity] else { return }
    current.paneStates = panes
    for pane in panes {
      // 解除の判定は生の状態で行う (§12.7)。安定化した状態で遅らせない。
      let display = completions.update(
        paneID: pane.id, completion: completionEntries[pane.id] ?? .unset, agentState: pane.state)
      current.details[pane.id, default: OverviewPaneDetail()].isTaskCompleted =
        display.isCompleted
    }
    observed[identity] = current
    stabilize(identity, at: clock.now)
    for continuation in subscribers[identity]?.values ?? [:].values {
      continuation.yield(panes)
    }
    notifier?.statesObserved(snapshot, in: identity)
  }

  private func stabilize(_ identity: WorktreeIdentity, at instant: ContinuousClock.Instant) {
    guard var current = observed[identity], let panes = current.paneStates else { return }
    var stabilizer = stabilizers[identity] ?? PaneDisplayStateStabilizer()
    current.displayStates = stabilizer.observe(panes, at: instant)
    stabilizers[identity] = stabilizer
    if observed[identity] != current {
      observed[identity] = current
    }
    observations[identity]?.deadline?.cancel()
    observations[identity]?.deadline = stabilizer.nextDeadline.map { deadline in
      Task { [weak self, clock] in
        do {
          try await clock.sleep(until: deadline)
        } catch {
          return
        }
        self?.stabilize(identity, at: deadline)
      }
    }
  }

  private func refreshSummaries(of identity: WorktreeIdentity) async {
    guard let paneSource, let signalSource else { return }
    let located: [LocatedPaneSummaryReadings]
    do {
      located = try await paneSource.locatedSummaryReadings(of: identity)
    } catch {
      // 読めなかった回は前回の概要を保つ。消すと、一時的な失敗で目的と現在地が瞬く。
      return
    }
    var details: [PaneID: OverviewPaneDetail] = [:]
    var processIDs: [PaneID: Int32] = [:]
    var entries: [PaneID: PaneSummaryEntry<AgentStampedValue>] = [:]
    var displays: [PaneID: PaneTaskCompletionDisplay] = [:]
    var undetermined: Set<PaneID> = []
    var summaries: [PaneSummary] = []
    for item in located {
      let snapshot = item.readings
      // 現在の Agent プロセスが要るのは PID 付きの値が書かれているときだけ。書かれていなければ
      // `PaneSummary` は PID を見ないので、共有の `ps` を引きに行かない。
      let agentProcess: PaneAgentProcess =
        if Self.hasValue(snapshot.readings.status) || Self.hasValue(snapshot.readings.completion) {
          await signalSource.agentProcess(
            for: snapshot.pane, matchingProcessNames: agentProcessNames)
        } else {
          .notRunning
        }
      let summary = PaneSummary(
        paneID: snapshot.pane.id, readings: snapshot.readings, agentProcess: agentProcess)
      summaries.append(summary)
      processIDs[summary.paneID] = snapshot.pane.processID
      details[summary.paneID] = OverviewPaneDetail(
        location: item.location, purpose: summary.purpose.value, status: summary.status.value)
    }
    guard !Task.isCancelled, var current = observed[identity] else { return }
    let rawStates = Dictionary(
      (current.paneStates ?? []).map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    for summary in summaries {
      let display = completions.update(
        paneID: summary.paneID, completion: summary.completion,
        agentState: rawStates[summary.paneID])
      entries[summary.paneID] = summary.completion
      displays[summary.paneID] = display
      if PaneTaskCompletionTracker.isUndetermined(summary.completion) {
        undetermined.insert(summary.paneID)
      }
      details[summary.paneID]?.isTaskCompleted = display.isCompleted
    }
    for paneID in current.details.keys where details[paneID] == nil {
      completions.forget(paneID: paneID)
      completionEntries[paneID] = nil
    }
    completionEntries.merge(entries) { _, new in new }
    current.details = details
    current.processIDs = processIDs
    if observed[identity] != current {
      observed[identity] = current
    }
    notifier?.completionsObserved(displays, undetermined: undetermined, in: identity)
  }

  private static func hasValue(_ reading: PaneUserOptionReading) -> Bool {
    if case .value(let raw) = reading { return !raw.isEmpty }
    return false
  }
}

extension PaneTaskCompletionDisplay {
  /// `.dismissed` は表示しない (同じ pane が再び Working になって解除された完了、§12.7)。
  fileprivate var isCompleted: Bool {
    if case .completed = self { return true }
    return false
  }
}
