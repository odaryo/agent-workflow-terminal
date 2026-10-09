/// Overview (設計書 §13) に出す pane 1つの状態。アイコンと並べ替えの両方がこれを使う。
public struct PaneDisplayState: Sendable, Hashable {
  public let paneID: PaneID
  public let state: AgentState
  /// `state == .unknown` でも `.needsAttention` になり得る (§12.4.3)。`state` から導かない。
  public let category: WorktreeStateCategory
  /// 表示する (`state`, `category`) が最後に変わった時刻。§13 の「最終更新順」の鍵。
  public let changedAt: ContinuousClock.Instant

  public init(
    paneID: PaneID, state: AgentState, category: WorktreeStateCategory,
    changedAt: ContinuousClock.Instant
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
  }

  private let holdDuration: Duration
  private var entries: [PaneID: Entry] = [:]

  public init(holdDuration: Duration = .seconds(9)) {
    self.holdDuration = holdDuration
  }

  public var nextDeadline: ContinuousClock.Instant? {
    entries.values.compactMap(\.stabilizer.pendingTransitionDeadline).min()
  }

  /// `panes` は Agent pane だけ (`.absent` を除いた観測)。入力から消えた pane は保持せずに外す —
  /// Agent が居なくなった pane を、居たときの状態のまま 9 秒並べない。
  public mutating func observe(
    _ panes: [PaneAgentState], at instant: ContinuousClock.Instant
  ) -> [PaneDisplayState] {
    let present = Set(panes.map(\.id))
    entries = entries.filter { present.contains($0.key) }
    return panes.map { pane in
      let observed = WorktreeRepresentativeState(
        category: pane.category, state: pane.state, paneID: pane.id)
      var entry =
        entries[pane.id]
        ?? Entry(
          stabilizer: WorktreeRepresentativeStateStabilizer(holdDuration: holdDuration),
          shown: PaneDisplayState(
            paneID: pane.id, state: pane.state, category: pane.category, changedAt: instant))
      let stabilized = entry.stabilizer.observe(state: observed, at: instant) ?? observed
      if stabilized.state != entry.shown.state || stabilized.category != entry.shown.category {
        entry.shown = PaneDisplayState(
          paneID: pane.id, state: stabilized.state, category: stabilized.category,
          changedAt: instant)
      }
      entries[pane.id] = entry
      return entry.shown
    }
  }
}
