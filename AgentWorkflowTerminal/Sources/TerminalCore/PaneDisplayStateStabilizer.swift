/// Overview (設計書 §13) に出す pane 1つの状態。アイコンと並べ替えの両方がこれを使う。
public struct PaneDisplayState: Sendable, Hashable {
  public let paneID: PaneID
  public let state: AgentState
  /// `state == .unknown` でも `.needsAttention` になり得る (§12.4.3)。`state` から導かない。
  public let category: WorktreeStateCategory
  /// `nil` は基準の観測に在った pane が、仮の Unknown から初めて状態が決まる変化を除き、
  /// まだ表示状態を変えていないことを表す。
  /// 初期表示を Adapter の到着順で並べないため、どの更新時刻よりも古い同順位として扱う (設計書 §13)。
  public let changedAt: ContinuousClock.Instant?

  public init(
    paneID: PaneID, state: AgentState, category: WorktreeStateCategory,
    changedAt: ContinuousClock.Instant?
  ) {
    self.paneID = paneID
    self.state = state
    self.category = category
    self.changedAt = changedAt
  }
}

/// pane ごとに §12.2 の代表状態と同じ安定化 (Idle / Unknown へ入る遷移を保持) を掛ける。
///
/// 生の観測で並べると、§12.2 が記録した `Working`↔`Unknown` の振動のたびに行が入れ替わり、
/// クリックの直前に別の pane の行が来て誤った pane へ移る (Issue #189)。
///
/// - Important: 保持は自律的に満了しない。上位レイヤは `nextDeadline` に、最後に渡した入力を
///   もう一度渡す義務がある (`WorktreeRepresentativeStateStabilizer` と同じ契約)。
/// - Note: タスク完了表示の解除 (`PaneTaskCompletionTracker`) にはこの結果ではなく生の状態を
///   渡す。解除の契機は応答終了から `Working` への遷移そのものであり、保持で遅らせない (§12.7)。
public struct PaneDisplayStateStabilizer: Sendable {
  private struct Entry: Sendable {
    var stabilizer: WorktreeRepresentativeStateStabilizer
    var shown: PaneDisplayState
    var awaitsInitialResolution: Bool
    var removalDeadline: ContinuousClock.Instant?
  }

  private let holdDuration: Duration
  private var entries: [PaneID: Entry] = [:]
  private var paneOrder: [PaneID] = []
  private var lastObservedAt: ContinuousClock.Instant?

  public init(holdDuration: Duration = .seconds(9)) {
    self.holdDuration = holdDuration
  }

  public var nextDeadline: ContinuousClock.Instant? {
    entries.values.flatMap { entry in
      [entry.stabilizer.pendingTransitionDeadline, entry.removalDeadline].compactMap { $0 }
    }.filter { deadline in
      // 消失中は表示を固定するため、過ぎた状態遷移期限で再観測を繰り返させない。
      lastObservedAt.map { deadline > $0 } ?? true
    }.min()
  }

  /// `panes` は Agent pane だけ (`.absent` を除いた観測)。一時的な観測消失で行と最終更新が
  /// 跳ねないよう、消失中は最後の表示を `holdDuration` の間保つ (設計書 §13)。
  public mutating func observe(
    _ panes: [PaneAgentState], at instant: ContinuousClock.Instant
  ) -> [PaneDisplayState] {
    let present = Set(panes.map(\.id))
    let isFirstObservation = lastObservedAt == nil
    let previous = paneOrder.compactMap { entries[$0]?.shown }
    lastObservedAt = instant
    for paneID in paneOrder {
      guard var entry = entries[paneID] else { continue }
      if !present.contains(paneID), entry.removalDeadline == nil {
        entry.removalDeadline = instant.advanced(by: holdDuration)
      }
      if let deadline = entry.removalDeadline, instant >= deadline {
        entries.removeValue(forKey: paneID)
      } else {
        entries[paneID] = entry
      }
    }
    for pane in panes {
      let observed = WorktreeRepresentativeState(
        category: pane.category, state: pane.state, paneID: pane.id)
      var entry =
        entries[pane.id]
        ?? Entry(
          stabilizer: WorktreeRepresentativeStateStabilizer(holdDuration: holdDuration),
          shown: PaneDisplayState(
            paneID: pane.id, state: pane.state, category: pane.category,
            changedAt: isFirstObservation ? nil : instant),
          awaitsInitialResolution: isFirstObservation
            && pane.state == .unknown && pane.category != .needsAttention)
      entry.removalDeadline = nil
      let stabilized = entry.stabilizer.observe(state: observed, at: instant) ?? observed
      let isInitialResolution =
        entry.awaitsInitialResolution
        && (stabilized.state != .unknown || stabilized.category == .needsAttention)
      if stabilized.state != entry.shown.state || stabilized.category != entry.shown.category {
        entry.shown = PaneDisplayState(
          paneID: pane.id, state: stabilized.state, category: stabilized.category,
          changedAt: entry.awaitsInitialResolution ? nil : instant)
      }
      if isInitialResolution { entry.awaitsInitialResolution = false }
      entries[pane.id] = entry
    }
    paneOrder = retainingMissingPanes(in: panes.map(\.id), previous: previous)
    return paneOrder.compactMap { entries[$0]?.shown }
  }

  private func retainingMissingPanes(
    in inputOrder: [PaneID], previous: [PaneDisplayState]
  ) -> [PaneID] {
    // 消失・復帰で同順位を逆転させないため、分類と最終更新が変わらない pane は前回順を保つ。
    // 新規・順位変更の pane は入力中の次の据え置き pane の直前へ、無ければ末尾へ入力順で挿入する。
    let retained = previous.filter { old in
      guard let shown = entries[old.paneID]?.shown else { return false }
      return shown.category == old.category && shown.changedAt == old.changedAt
    }
    let retainedIDs = Set(retained.map(\.paneID))
    var preceding: [PaneID: [PaneID]] = [:]
    var pending: [PaneID] = []
    for paneID in inputOrder {
      if retainedIDs.contains(paneID) {
        preceding[paneID] = pending
        pending = []
      } else {
        pending.append(paneID)
      }
    }
    return retained.flatMap { (preceding[$0.paneID] ?? []) + [$0.paneID] } + pending
  }
}
