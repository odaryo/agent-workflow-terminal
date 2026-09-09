public protocol WorktreePaneSource: Sendable {
  /// 実装体は tmux `list-panes` の順序を保つ。session がまだ無ければ throw せず空配列を返す。
  func panes(of worktree: WorktreeIdentity) async throws -> [PaneSnapshot]
}

public struct WorktreePaneAgentStateFeed: Sendable {
  private let adapters: [any AgentAdapter]
  private let fallback: any AgentAdapter
  private let intervals: AgentObservationIntervals
  private let paneListInterval: Duration

  public init(
    adapters: [any AgentAdapter],
    fallback: any AgentAdapter,
    intervals: AgentObservationIntervals,
    paneListInterval: Duration
  ) {
    self.adapters = adapters
    self.fallback = fallback
    self.intervals = intervals
    self.paneListInterval = paneListInterval
  }

  /// `.absent` の pane は、非 Agent process を代表状態へ昇格させないため出力に含めない
  /// (設計書 §5.2)。空配列は Agent pane が1つも無いことを表し、代表状態の `nil` を Idle 表示へ
  /// 変換する規則は表示層に留める。
  public func states(
    of worktree: WorktreeIdentity,
    panes paneSource: any WorktreePaneSource,
    signals signalSource: any AgentSignalSource,
    timeSource: any ContinuousTimeSource = SystemContinuousTimeSource()
  ) -> AsyncStream<[PaneAgentState]> {
    AsyncStream { continuation in
      let coordinator = WorktreePaneFeedCoordinator(
        adapters: adapters,
        fallback: fallback,
        intervals: intervals,
        continuation: continuation,
        signalSource: signalSource
      )
      let pollTask = Task {
        while !Task.isCancelled {
          do {
            let panes = try await paneSource.panes(of: worktree)
            guard !Task.isCancelled else { break }
            await coordinator.receive(panes)
          } catch {
            guard !Task.isCancelled else { break }
          }

          do {
            try await timeSource.sleep(until: timeSource.now.advanced(by: paneListInterval))
          } catch {
            break
          }
        }
      }
      Task { await coordinator.setPollTask(pollTask) }
      continuation.onTermination = { _ in
        pollTask.cancel()
        Task { await coordinator.cancel() }
      }
    }
  }
}

actor WorktreePaneFeedCoordinator {
  private struct PaneEntry {
    var snapshot: PaneSnapshot
    var result: AgentObservationResult?
    var task: Task<Void, Never>?
    var generation: Int
  }

  private let adapters: [any AgentAdapter]
  private let fallback: any AgentAdapter
  private let intervals: AgentObservationIntervals
  private let continuation: AsyncStream<[PaneAgentState]>.Continuation
  private let signalSource: any AgentSignalSource
  private var paneOrder: [PaneID] = []
  private var entries: [PaneID: PaneEntry] = [:]
  private var lastYielded: [PaneAgentState]?
  private var pollTask: Task<Void, Never>?
  private var isCancelled = false

  init(
    adapters: [any AgentAdapter],
    fallback: any AgentAdapter,
    intervals: AgentObservationIntervals,
    continuation: AsyncStream<[PaneAgentState]>.Continuation,
    signalSource: any AgentSignalSource
  ) {
    self.adapters = adapters
    self.fallback = fallback
    self.intervals = intervals
    self.continuation = continuation
    self.signalSource = signalSource
  }

  func setPollTask(_ task: Task<Void, Never>) {
    guard !isCancelled else {
      task.cancel()
      return
    }
    pollTask = task
  }

  func receive(_ panes: [PaneSnapshot]) async {
    guard !isCancelled else { return }
    let paneIDs = Set(panes.map(\.id))
    let removed = entries.keys.filter { !paneIDs.contains($0) }
    for paneID in removed {
      guard let entry = entries.removeValue(forKey: paneID) else { continue }
      entry.task?.cancel()
      await signalSource.forget(entry.snapshot)
    }

    paneOrder = panes.map(\.id)
    for pane in panes {
      if let entry = entries[pane.id] {
        if needsReselection(previous: entry.snapshot, current: pane) {
          entry.task?.cancel()
          // pane も Agent も生きている間に観測できないことを「不在」として報告しない。
          // 本当の不在は新しい adapter の `.absent` で確定する (設計書 §12.3 / §12.4.2)。
          entries[pane.id] = PaneEntry(
            snapshot: pane, result: entry.result, task: nil, generation: entry.generation + 1)
          await startObservation(for: pane)
        } else {
          entries[pane.id]?.snapshot = pane
        }
      } else {
        entries[pane.id] = PaneEntry(snapshot: pane, result: nil, task: nil, generation: 0)
        await startObservation(for: pane)
      }
    }
    yieldIfChanged()
  }

  func receive(_ result: AgentObservationResult, paneID: PaneID, generation: Int) {
    guard !isCancelled, entries[paneID]?.generation == generation else { return }
    entries[paneID]?.result = result
    yieldIfChanged()
  }

  /// `AgentSignalSource` はアプリ全体で1個を共有し、pane ごとの登録集合をその内側に持つ
  /// (`TmuxAgentSignalSource` は capture をバッチ化するため、`signals(for:)` を受けた pane を
  /// 登録する)。よって feed を止める側には、登録した pane を解放する義務がある。怠ると、
  /// 止めた worktree の pane が生きている worktree のバッチへ相乗りし続け、登録集合が
  /// アプリの寿命で単調に増える。**外部プロセスの起動回数は増えない** (バッチは
  /// `signals(for:)` からしか起きないので、feed が全部止まればバッチも止まる) が、
  /// 1バッチあたりの捕捉対象と出力量が増え続ける。#331 が非アクティブ worktree の観測停止を
  /// 常用経路にしたので、これは日常的に起きる。
  ///
  /// - Note: `isCancelled` を先に立てるので、`await` を挟んで再入しても `receive` /
  ///   `setPollTask` はいずれも早期 return する。
  /// - Note: 観測 Task の停止は非同期なので、`cancel()` の直前に始まっていた `signals(for:)`
  ///   が解放の**後**に pane を再登録する窓は残る。これは `receive(_ panes:)` の削除経路が
  ///   元から持っている窓と同じで、閉じるには観測 Task の完了待ちが要る。
  func cancel() async {
    guard !isCancelled else { return }
    isCancelled = true
    pollTask?.cancel()
    let released = entries.values.map(\.snapshot)
    for entry in entries.values {
      entry.task?.cancel()
    }
    entries.removeAll()
    paneOrder.removeAll()
    continuation.finish()
    for snapshot in released {
      await signalSource.forget(snapshot)
    }
  }

  private func startObservation(for pane: PaneSnapshot) async {
    // `liveness` は状態取得の約8倍のコストがあるため、毎 poll ではなく前景プロセスが変わった
    // pane だけを再選択する。`currentCommand` は検出トリガに限り、選択は設計書 §12.1 / §12.4.2
    // のとおり process table を見る resolver に委ねる。
    var candidates: [AgentAdapterCandidate] = []
    for adapter in adapters {
      let liveness = await signalSource.liveness(
        for: pane, matchingProcessNames: adapter.processNames)
      candidates.append(AgentAdapterCandidate(adapter: adapter, liveness: liveness))
    }
    guard !isCancelled, entries[pane.id] != nil else { return }
    let adapter = AgentAdapterResolver.resolve(
      pane: pane, candidates: candidates, fallback: fallback)
    let observations = adapter.observations(of: pane, from: signalSource, intervals: intervals)
    guard let generation = entries[pane.id]?.generation else { return }
    let task = Task {
      for await result in observations {
        guard !Task.isCancelled else { break }
        receive(result, paneID: pane.id, generation: generation)
      }
    }
    entries[pane.id]?.task = task
  }

  private func needsReselection(previous: PaneSnapshot, current: PaneSnapshot) -> Bool {
    previous.processID != current.processID || previous.currentCommand != current.currentCommand
      || previous.isDead != current.isDead
  }

  private func yieldIfChanged() {
    let value = paneOrder.compactMap { paneID -> PaneAgentState? in
      guard case .observation(let observation) = entries[paneID]?.result else { return nil }
      return PaneAgentState(id: paneID, observation: observation)
    }
    guard value != lastYielded else { return }
    lastYielded = value
    continuation.yield(value)
  }
}
