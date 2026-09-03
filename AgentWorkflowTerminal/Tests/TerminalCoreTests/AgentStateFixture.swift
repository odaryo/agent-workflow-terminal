import Foundation
import Testing

@testable import TerminalCore

struct AgentStateFixture: Decodable {
  let source: String
  let acceptableStates: [String]
  let paneTitle: String
  let secondsSinceScreenChange: TimeInterval?
  let processNames: [String]
  let screen: String

  var signals: AgentSignals {
    AgentSignals(
      paneTitle: paneTitle,
      screenText: screen,
      secondsSinceScreenChange: secondsSinceScreenChange,
      observedAt: Date(timeIntervalSince1970: 2)
    )
  }

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
