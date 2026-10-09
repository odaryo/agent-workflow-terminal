import Foundation
import TerminalCore
import Testing

/// `PaneNotificationPlanner` のテストが共有する入力と手順。
protocol PaneNotificationPlannerTesting {
  var worktree: WorktreeIdentity { get }
  var other: WorktreeIdentity { get }
}

extension PaneNotificationPlannerTesting {
  static var clock: ContinuousClock { ContinuousClock() }
  static var first: AgentStampedValue { AgentStampedValue(agentProcessID: 42, text: "t1") }
  static var second: AgentStampedValue { AgentStampedValue(agentProcessID: 42, text: "t2") }
  static var withProlongedUnknown: PaneNotificationSettings {
    PaneNotificationSettings(
      enabledKinds: PaneNotificationSettings().enabledKinds.union([.prolongedUnknown]))
  }

  static var withoutUnspecified: PaneNotificationSettings {
    PaneNotificationSettings(
      enabledKinds: PaneNotificationSettings().enabledKinds.subtracting([.attentionUnspecified]))
  }

  static func identities() throws -> (worktree: WorktreeIdentity, other: WorktreeIdentity) {
    (
      try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/a")),
      try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/b"))
    )
  }

  func started(
    settings: PaneNotificationSettings = PaneNotificationSettings()
  ) -> PaneNotificationPlanner {
    var planner = PaneNotificationPlanner(settings: settings)
    planner.startObserving(worktree, at: Self.clock.now)
    return planner
  }

  /// 基準を取り、起動直後のまとめ通知も済ませた状態。
  func baselined(
    _ panes: [PaneAgentState], at instant: ContinuousClock.Instant = Self.clock.now,
    settings: PaneNotificationSettings = PaneNotificationSettings()
  ) -> PaneNotificationPlanner {
    var planner = PaneNotificationPlanner(settings: settings)
    planner.startObserving(worktree, at: instant)
    _ = planner.observeStates(complete(panes), in: worktree, at: instant)
    _ = planner.setSummaryGate(isOpen: true, at: instant)
    return planner
  }

  func completionBaselined(
    _ displays: [String: PaneTaskCompletionDisplay],
    settings: PaneNotificationSettings = PaneNotificationSettings()
  ) -> PaneNotificationPlanner {
    var planner = baselined([], settings: settings)
    _ = planner.observeCompletions(
      Self.keyed(displays), undetermined: [], in: worktree, at: Self.clock.now)
    return planner
  }

  static func keyed(
    _ displays: [String: PaneTaskCompletionDisplay]
  ) -> [PaneID: PaneTaskCompletionDisplay] {
    Dictionary(uniqueKeysWithValues: displays.map { (PaneID(rawValue: $0.key), $0.value) })
  }

  func observe(
    _ planner: inout PaneNotificationPlanner, _ panes: [PaneAgentState]
  ) -> [PaneNotification] {
    planner.observeStates(complete(panes), in: worktree, at: Self.clock.now)
  }

  /// `undetermined` は Agent プロセスを特定できなかった pane。
  func completions(
    _ planner: inout PaneNotificationPlanner, _ displays: [String: PaneTaskCompletionDisplay],
    undetermined: Set<String> = []
  ) -> [PaneNotification] {
    planner.observeCompletions(
      Self.keyed(displays), undetermined: Set(undetermined.map(PaneID.init(rawValue:))),
      in: worktree, at: Self.clock.now)
  }

  func event(
    _ paneID: String, _ kind: PaneNotificationKind, completion: AgentStampedValue? = nil
  ) -> PaneNotification {
    .pane(
      PaneNotificationEvent(
        worktree: worktree, paneID: PaneID(rawValue: paneID), kind: kind,
        completion: completion))
  }

  func complete(_ panes: [PaneAgentState]) -> WorktreePaneAgentStates {
    WorktreePaneAgentStates(panes: panes, isComplete: true)
  }

  func incomplete(_ panes: [PaneAgentState]) -> WorktreePaneAgentStates {
    WorktreePaneAgentStates(panes: panes, isComplete: false)
  }

  func pane(_ id: String, _ state: AgentState) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      observation: AgentStateObservation(
        state: state, adapterID: AgentAdapterID(rawValue: "test"),
        observedAt: Date(timeIntervalSince1970: 0)))
  }

  func attentionUnknown(_ id: String) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      observation: AgentStateObservation(
        state: .unknown, adapterID: AgentAdapterID(rawValue: "test"),
        observedAt: Date(timeIntervalSince1970: 0), category: .needsAttention,
        unknownReason: .adapterUndetermined))
  }
}
