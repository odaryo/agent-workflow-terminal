import Foundation
import TerminalCore
import Testing

@Suite("応答終了の最終観測時刻 (設計書 §12.7 / Issue #386)")
struct AgentTurnEndObservationTests {
  private let pane = PaneSnapshot(
    id: PaneID(rawValue: "%1"), processID: 1, tty: "", currentCommand: "",
    currentPath: "", title: "", termination: nil)

  @Test(
    "配信しない回も応答終了の時刻を更新し、Unknown・Question・観測失敗は更新しない",
    arguments: [AgentState.completed, .idle], ["direct", "unknown", "question", "failure"])
  func latestTurnEndIncludesSuppressedObservations(
    turnEnd: AgentState, between: String
  ) async throws {
    var samples = [10, 12, 14, 16].map {
      TurnEndSignalSource.Sample.observation(turnEnd, TimeInterval($0))
    }
    switch between {
    case "unknown": samples.append(.observation(.unknown, 18))
    case "question": samples.append(.observation(.question, 18))
    case "failure": samples.append(.failure)
    default: break
    }
    samples.append(.observation(.working, 20))
    let observations = await collectThroughWorking(samples)
    #expect(observations.map(\.state) == [turnEnd] + intermediateStates(between) + [.working])
    let first = try #require(observations.first)
    #expect(first.observedAt == Date(timeIntervalSince1970: 10))
    #expect(first.lastTurnEndObservedAt == Date(timeIntervalSince1970: 10))
    for observation in observations.dropFirst() {
      #expect(observation.lastTurnEndObservedAt == Date(timeIntervalSince1970: 16))
    }
    let working = try #require(observations.last)
    #expect(working.observedAt == Date(timeIntervalSince1970: 20))
    if between == "failure" {
      #expect(observations.dropFirst().first?.unknownReason == .observationFailed)
    }
  }

  @Test("応答終了を一度も観測しなければ nil", arguments: ["unknown", "question", "failure", "direct"])
  func noTurnEndLeavesTimeNil(before: String) async {
    var samples: [TurnEndSignalSource.Sample] = []
    switch before {
    case "unknown": samples.append(.observation(.unknown, 10))
    case "question": samples.append(.observation(.question, 10))
    case "failure": samples.append(.failure)
    default: break
    }
    samples.append(.observation(.working, 20))
    let observations = await collectThroughWorking(samples)
    #expect(observations.map(\.state) == intermediateStates(before) + [.working])
    #expect(observations.allSatisfy { $0.lastTurnEndObservedAt == nil })
  }

  @Test("時刻を指定しない初期化では観測と pane の応答終了時刻は nil")
  func initializersDefaultToNil() {
    let observation = AgentStateObservation(
      state: .completed, adapterID: AgentAdapterID(rawValue: "test"), observedAt: .distantPast)
    #expect(observation.lastTurnEndObservedAt == nil)
    #expect(PaneAgentState(id: pane.id, observation: observation).lastTurnEndObservedAt == nil)
    #expect(
      PaneAgentState(id: pane.id, state: .completed, lastUpdatedAt: .distantPast)
        .lastTurnEndObservedAt == nil)
  }

  private func intermediateStates(_ step: String) -> [AgentState] {
    switch step {
    case "unknown", "failure": [.unknown]
    case "question": [.question]
    default: []
    }
  }

  private func collectThroughWorking(
    _ samples: [TurnEndSignalSource.Sample]
  ) async -> [AgentStateObservation] {
    let stream = TurnEndTestAdapter().observations(
      of: pane, from: TurnEndSignalSource(samples: samples),
      intervals: AgentObservationIntervals(signals: .milliseconds(1), liveness: .seconds(1)))
    var observations: [AgentStateObservation] = []
    for await result in stream {
      guard case .observation(let observation) = result else {
        Issue.record("偽 source の観測が必要")
        break
      }
      observations.append(observation)
      if observation.state == .working { break }
    }
    return observations
  }
}

private struct TurnEndTestAdapter: AgentAdapter {
  let id = AgentAdapterID(rawValue: "test")
  let processNames: Set<String> = ["test"]

  func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult {
    .observation(
      AgentStateObservation(
        state: AgentState(rawValue: signals.paneTitle) ?? .unknown,
        adapterID: id, observedAt: signals.observedAt))
  }
}

private actor TurnEndSignalSource: AgentSignalSource {
  enum Sample: Sendable {
    case observation(AgentState, TimeInterval)
    case failure
  }

  private enum Failure: Error {
    case observationFailed
  }

  private var samples: [Sample]

  init(samples: [Sample]) {
    self.samples = samples
  }

  func signals(for pane: PaneSnapshot, minimumChangedLines: Int) async throws -> AgentSignals {
    guard !samples.isEmpty else { throw Failure.observationFailed }
    switch samples.removeFirst() {
    case .failure: throw Failure.observationFailed
    case .observation(let state, let seconds):
      return AgentSignals(
        paneTitle: state.rawValue, screenText: "", styledScreenText: nil,
        secondsSinceScreenChange: nil, hasObservedScreenChange: false,
        observedAt: Date(timeIntervalSince1970: seconds))
    }
  }

  func liveness(for pane: PaneSnapshot, matchingProcessNames: Set<String>) async -> AgentLiveness {
    .alive
  }
}
