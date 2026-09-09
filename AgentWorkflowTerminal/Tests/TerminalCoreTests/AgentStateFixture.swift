import Foundation
import Testing

@testable import TerminalCore

struct AgentStateFixture: Decodable {
  /// JSON には無く、`load(prefix:)` が読み出したファイル名から入れる。
  /// `source` は取得手順を書いた fixture があり、ファイル名の代理にならない。
  private(set) var fileName = ""

  let source: String
  let expectedState: String
  let acceptableStates: [String]
  let paneTitle: String
  let secondsSinceScreenChange: TimeInterval?
  let processNames: [String]
  let screen: String
  /// `capture-pane -e -p` を採った fixture だけが持つ。属性なしで採った旧 fixture では
  /// `nil` になり、実路で属性を観測できなかった場合と同じ入力になる。
  let styledScreen: String?

  // 以下4つは optional にしない。省略した fixture を足すと decode で落ちるので、版数を書き忘れた
  // まま追加できなくなる (`docs/coding-guidelines.md` §3.2)。Claude Code 2.1.259 → 2.1.263 の
  // ドリフトを 476 件の GREEN が見逃した (#217) のは、版数が JSON に書いてあるだけで
  // decode されていなかったため。
  let agentVersion: String
  let tmuxVersion: String
  let os: String
  let capturedAt: String
  /// 記録の残っている fixture だけが持つ。旧 fixture は採取コマンドを残していない。
  let captureCommand: String?

  private enum CodingKeys: String, CodingKey {
    case source, expectedState, acceptableStates, paneTitle, secondsSinceScreenChange
    case processNames, screen, styledScreen
    case agentVersion, tmuxVersion, os, capturedAt, captureCommand
  }

  var signals: AgentSignals {
    AgentSignals(
      paneTitle: paneTitle,
      screenText: screen,
      styledScreenText: styledScreen,
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
    .map { url in
      let fileName = url.deletingPathExtension().lastPathComponent
      do {
        var fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        fixture.fileName = fileName
        return fixture
      } catch {
        // 版数を書き忘れた fixture を足すと落ちるのが狙いなので、書き足す先が生出力から
        // 分かる必要がある。DecodingError はキー名しか持たない。
        throw AgentStateFixtureLoadFailure(fileName: fileName, underlying: error)
      }
    }
  }
}

struct AgentStateFixtureLoadFailure: Error, CustomStringConvertible {
  let fileName: String
  let underlying: any Error

  var description: String { "\(fileName): \(underlying)" }
}

func fixtureState(of result: AgentObservationResult) -> String {
  switch result {
  case .absent: "absent"
  case .observation(let observation): observation.state.rawValue
  }
}
