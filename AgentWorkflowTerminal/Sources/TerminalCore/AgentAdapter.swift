import Foundation

public struct AgentAdapterID: Sendable, Hashable, Codable, RawRepresentable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

/// renderer にプロセス観測を寄せないのは、libghostty v1.3.1 に必要な API が無いため
/// (Spikes/gate1/README.md §8.10、設計書 §21.3)。
public struct PaneSnapshot: Sendable, Hashable, Codable {
  public let id: PaneID
  /// dead pane では終了済み PID が残り、OS に再利用され得るため生存確認に使わない。
  public let processID: Int32
  public let tty: String
  public let currentCommand: String
  /// dead pane では空になり得るため、空文字列を観測失敗として扱わない。
  public let currentPath: String
  public let title: String
  public let termination: ProcessTermination?
  public var isDead: Bool { termination != nil }

  public init(
    id: PaneID, processID: Int32, tty: String, currentCommand: String,
    currentPath: String, title: String, termination: ProcessTermination?
  ) {
    self.id = id
    self.processID = processID
    self.tty = tty
    self.currentCommand = currentCommand
    self.currentPath = currentPath
    self.title = title
    self.termination = termination
  }
}

public enum UnknownReason: String, Sendable, Hashable, Codable {
  case screenUnavailable
  case signalMissing
  case adapterUndetermined
}

public enum AgentLiveness: String, Sendable, Hashable, Codable {
  case alive
  case absent
  case undetermined
}

public struct AgentSignals: Sendable, Hashable, Codable {
  public let paneTitle: String
  public let screenText: String?
  public let secondsSinceOutput: TimeInterval?
  public let isPaneInMode: Bool
  public let observedAt: Date

  public init(
    paneTitle: String, screenText: String?, secondsSinceOutput: TimeInterval?,
    isPaneInMode: Bool, observedAt: Date
  ) {
    self.paneTitle = paneTitle
    self.screenText = screenText
    self.secondsSinceOutput = secondsSinceOutput
    self.isPaneInMode = isPaneInMode
    self.observedAt = observedAt
  }
}

public protocol AgentSignalSource: Sendable {
  func signals(for pane: PaneSnapshot) async throws -> AgentSignals
  func liveness(for pane: PaneSnapshot, matchingProcessNames: Set<String>) async -> AgentLiveness
}

public struct AgentObservationIntervals: Sendable, Hashable {
  public let signals: Duration
  public let liveness: Duration
  public init(signals: Duration, liveness: Duration) {
    self.signals = signals
    self.liveness = liveness
  }
}

public struct AgentStateObservation: Sendable, Hashable, Codable {
  public let state: AgentState
  public let category: WorktreeStateCategory
  public let adapterID: AgentAdapterID
  public let observedAt: Date
  /// 状態を確定できた直近の時刻。一度も確定できていなければ `nil`。
  public let lastKnownAt: Date?
  public let diagnostics: String?
  public let unknownReason: UnknownReason?

  public init(
    state: AgentState, adapterID: AgentAdapterID, observedAt: Date,
    category: WorktreeStateCategory? = nil, lastKnownAt: Date? = nil,
    diagnostics: String? = nil, unknownReason: UnknownReason? = nil
  ) {
    self.state = state
    self.category = category ?? state.worktreeCategory
    self.adapterID = adapterID
    self.observedAt = observedAt
    self.lastKnownAt = lastKnownAt
    self.diagnostics = diagnostics
    self.unknownReason = unknownReason
  }
}

public enum AgentObservationResult: Sendable, Hashable, Codable {
  case observation(AgentStateObservation)
  case absent
}

public protocol AgentAdapter: Sendable {
  var id: AgentAdapterID { get }
  var processNames: Set<String> { get }
  func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult
  func observations(
    of pane: PaneSnapshot, from source: any AgentSignalSource,
    intervals: AgentObservationIntervals
  ) -> AsyncStream<AgentObservationResult>
}

extension AgentAdapter {
  public func observations(
    of pane: PaneSnapshot, from source: any AgentSignalSource,
    intervals: AgentObservationIntervals
  ) -> AsyncStream<AgentObservationResult> {
    AsyncStream { continuation in
      let task = Task {
        var liveness = AgentLiveness.undetermined
        var nextLivenessCheck: ContinuousClock.Instant?
        var previous: AgentObservationResult?
        var lastKnownAt: Date?
        let clock = ContinuousClock()
        while !Task.isCancelled {
          let now = clock.now
          if nextLivenessCheck.map({ now >= $0 }) ?? true {
            liveness = await source.liveness(for: pane, matchingProcessNames: processNames)
            nextLivenessCheck = now.advanced(by: intervals.liveness)
          }
          let result: AgentObservationResult
          if liveness == .absent {
            result = .absent
          } else {
            do {
              let classified = classify(
                signals: try await source.signals(for: pane), liveness: liveness
              )
              result = Self.withLastKnownAt(classified, previous: &lastKnownAt)
            } catch {
              result = .observation(
                AgentStateObservation(
                  state: .unknown, adapterID: id, observedAt: Date(),
                  diagnostics: String(describing: error), unknownReason: .screenUnavailable
                ))
            }
          }
          if !Self.isSameObservation(result, previous) {
            continuation.yield(result)
            previous = result
          }
          do { try await Task.sleep(for: intervals.signals) } catch { break }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func isSameObservation(
    _ lhs: AgentObservationResult, _ rhs: AgentObservationResult?
  ) -> Bool {
    guard let rhs else { return false }
    switch (lhs, rhs) {
    case (.absent, .absent): return true
    case (.observation(let lhs), .observation(let rhs)):
      return lhs.state == rhs.state && lhs.category == rhs.category
        && lhs.unknownReason == rhs.unknownReason && lhs.diagnostics == rhs.diagnostics
    default: return false
    }
  }

  private static func withLastKnownAt(
    _ result: AgentObservationResult, previous lastKnownAt: inout Date?
  ) -> AgentObservationResult {
    guard case .observation(let observation) = result else { return result }
    if observation.state != .unknown {
      lastKnownAt = observation.observedAt
    }
    return .observation(
      AgentStateObservation(
        state: observation.state, adapterID: observation.adapterID,
        observedAt: observation.observedAt, category: observation.category,
        lastKnownAt: lastKnownAt, diagnostics: observation.diagnostics,
        unknownReason: observation.unknownReason
      ))
  }
}
