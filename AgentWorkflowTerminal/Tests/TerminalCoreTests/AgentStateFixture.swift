import Foundation
import Testing

@testable import TerminalCore

struct AgentStateFixture: Decodable {
  let source: String
  let acceptableStates: [String]
  let paneTitle: String
  let processNames: [String]
  let screen: String

  func signals(screenChanged: Bool) -> AgentSignals {
    let paneID = PaneID(rawValue: "%fixture")
    let observedAt = Date(timeIntervalSince1970: 2)
    var tracker = AgentScreenChangeTracker()
    let previousScreen = screenChanged ? screen + " previous frame" : screen
    _ = tracker.observe(
      screen: previousScreen, paneID: paneID,
      at: Date(timeIntervalSince1970: 0)
    )
    let secondsSinceScreenChange = tracker.observe(
      screen: screen, paneID: paneID, at: observedAt
    )
    return AgentSignals(
      paneTitle: paneTitle,
      screenText: screen,
      secondsSinceScreenChange: secondsSinceScreenChange,
      observedAt: observedAt
    )
  }

  var signals: AgentSignals { signals(screenChanged: acceptableStates.contains("working")) }

  var liveness: AgentLiveness { processNames.isEmpty ? .absent : .alive }

  static func load(prefix: String) throws -> [Self] {
    let root = try #require(
      Bundle.module.resourceURL?.appending(path: "Fixtures/AgentState")
    )
    return try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { try JSONDecoder().decode(Self.self, from: Data(contentsOf: $0)) }
  }
}

func fixtureState(of result: AgentObservationResult) -> String {
  switch result {
  case .absent: "absent"
  case .observation(let observation): observation.state.rawValue
  }
}
