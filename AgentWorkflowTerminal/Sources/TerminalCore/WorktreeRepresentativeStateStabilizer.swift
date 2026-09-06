public struct WorktreeRepresentativeStateStabilizer: Sendable {
  private struct PendingTransition: Sendable {
    var state: WorktreeRepresentativeState?
    let startedAt: ContinuousClock.Instant
  }

  private let holdDuration: Duration
  private var hasDisplayedState = false
  private var displayedState: WorktreeRepresentativeState?
  private var pendingTransition: PendingTransition?

  /// 既定の保持時間は設計書 §12.2 による。
  public init(holdDuration: Duration = .seconds(10)) {
    self.holdDuration = holdDuration
  }

  public mutating func observe(
    state observedState: WorktreeRepresentativeState?,
    at observedAt: ContinuousClock.Instant
  ) -> WorktreeRepresentativeState? {
    guard hasDisplayedState else {
      hasDisplayedState = true
      displayedState = observedState
      return displayedState
    }

    let observedCategory = category(of: observedState)
    if observedCategory == category(of: displayedState) || !observedCategory.requiresHold {
      displayedState = observedState
      pendingTransition = nil
      return displayedState
    }

    if pendingTransition == nil {
      pendingTransition = PendingTransition(state: observedState, startedAt: observedAt)
    } else {
      pendingTransition?.state = observedState
    }

    if let pendingTransition,
      pendingTransition.startedAt.duration(to: observedAt) >= holdDuration
    {
      displayedState = pendingTransition.state
      self.pendingTransition = nil
    }

    return displayedState
  }

  private func category(
    of state: WorktreeRepresentativeState?
  ) -> WorktreeStateCategory {
    state?.category ?? .idle
  }
}

extension WorktreeStateCategory {
  fileprivate var requiresHold: Bool {
    self == .idle || self == .unknown
  }
}
