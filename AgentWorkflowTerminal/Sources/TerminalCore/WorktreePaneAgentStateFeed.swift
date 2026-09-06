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

private actor WorktreePaneFeedCoordinator {
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
          entries[pane.id] = PaneEntry(
            snapshot: pane, result: nil, task: nil, generation: entry.generation + 1)
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

  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    pollTask?.cancel()
    for entry in entries.values {
      entry.task?.cancel()
    }
    entries.removeAll()
    continuation.finish()
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
