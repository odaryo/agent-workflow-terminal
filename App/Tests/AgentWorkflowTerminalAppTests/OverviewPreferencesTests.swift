import Foundation
import Testing

@testable import AgentWorkflowTerminalApp

struct OverviewPreferencesTests {
  @Test(
    "§13 保存値が読めなければウィンドウ表示にする", arguments: [nil, "", "Sidebar", "side", "window "] as [String?])
  func unknownValueIsWindow(value: String?) {
    #expect(OverviewPresentation(storedValue: value) == .window)
  }

  @Test("§13 保存値の window と sidebar を読む")
  func knownValues() {
    #expect(OverviewPresentation(storedValue: "window") == .window)
    #expect(OverviewPresentation(storedValue: "sidebar") == .sidebar)
  }

  @Test("サイドバーの幅は 240〜480 に収め、非有限値は既定へ戻す")
  func widthClamp() {
    #expect(OverviewSidebarPreferences.clamped(100) == 240)
    #expect(OverviewSidebarPreferences.clamped(600) == 480)
    #expect(OverviewSidebarPreferences.clamped(333) == 333)
    #expect(OverviewSidebarPreferences.clamped(.nan) == 300)
    #expect(OverviewSidebarPreferences.clamped(.infinity) == 300)
  }

  @Test("閉じている間は最小幅へ何も足さない")
  func occupiedWidth() {
    #expect(OverviewSidebarPreferences.occupiedWidth(isVisible: false, width: 300) == 0)
    #expect(OverviewSidebarPreferences.occupiedWidth(isVisible: true, width: 300) == 308)
  }
}
