import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

struct ViewerArrangementPreferencesTests {
  @Test("保存値が読めなければ既定の並びで始める", arguments: [Data(), Data("{".utf8), Data("[]".utf8)])
  func invalidData(data: Data) throws {
    let name = "ViewerArrangementPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(data, forKey: ViewerArrangementPreferences.key)
    #expect(ViewerArrangementPreferences.load(from: defaults) == .defaults)
  }

  @Test("次の Project と再起動で Code と Diff の最後の並びを復元する")
  func roundTrip() throws {
    let name = "ViewerArrangementPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(ViewerArrangementPreferences.load(from: defaults) == .defaults)
    var first = ViewerDrawerLayout(arrangements: ViewerArrangementPreferences.load(from: defaults))
    first.setArrangement(.stacked, for: .code)
    first.setArrangement(.sideBySide, for: .diff)
    ViewerArrangementPreferences.save(first.arrangements, to: defaults)

    let reopenedDefaults = try #require(UserDefaults(suiteName: name))
    let second = ViewerDrawerLayout(
      arrangements: ViewerArrangementPreferences.load(from: reopenedDefaults))
    #expect(second.arrangements == first.arrangements)
    #expect(!second.isOpen)
  }
}
