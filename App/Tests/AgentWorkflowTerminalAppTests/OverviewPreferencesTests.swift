import Testing

@testable import AgentWorkflowTerminalApp

struct OverviewPreferencesTests {
  @Test("§13 表示中のセッションのProjectを閉じる")
  func collapseProject() throws {
    let storedValue = try #require(
      OverviewProjectPreferences.storedValue("[]", settingCollapsed: true, for: "project-a"))
    #expect(OverviewProjectPreferences.collapsedProjects(storedValue: storedValue) == ["project-a"])
  }

  @Test("§13 表示中のセッションのProjectを開く")
  func expandProject() {
    #expect(
      OverviewProjectPreferences.storedValue(
        #"["project-a"]"#, settingCollapsed: false, for: "project-a") == "[]")
  }

  @Test("§13 同じ開閉状態を指定しても保存値は変わらない", arguments: [true, false])
  func unchangedProjectState(collapsed: Bool) throws {
    let initial = try #require(
      OverviewProjectPreferences.storedValue(
        for: collapsed ? ["project-a", "project-b"] : ["project-b"]))
    #expect(
      OverviewProjectPreferences.storedValue(initial, settingCollapsed: collapsed, for: "project-a")
        == initial)
  }

  @Test("§13 壊れた保存値からでもProjectを閉じられる")
  func collapseProjectWithBrokenStoredValue() throws {
    let storedValue = try #require(
      OverviewProjectPreferences.storedValue("{broken", settingCollapsed: true, for: "project-a"))
    #expect(OverviewProjectPreferences.collapsedProjects(storedValue: storedValue) == ["project-a"])
  }

  @Test("§13 Projectの開閉は他のProjectの状態を保つ", arguments: [true, false])
  func preservesOtherProjects(collapsed: Bool) throws {
    let initial =
      collapsed ? #"["project-b","project-c"]"# : #"["project-b","project-a","project-c"]"#
    let storedValue = try #require(
      OverviewProjectPreferences.storedValue(
        initial, settingCollapsed: collapsed, for: "project-a"))
    let expected: Set<String> =
      collapsed ? ["project-a", "project-b", "project-c"] : ["project-b", "project-c"]
    #expect(OverviewProjectPreferences.collapsedProjects(storedValue: storedValue) == expected)
  }

  @Test("§13 サイドバーは既定で開く")
  func sidebarIsOpenByDefault() {
    #expect(OverviewSidebarPreferences.defaultIsOpen)
  }

  @Test("サイドバーの幅は 160〜480 に収め、非有限値は既定へ戻す")
  func widthClamp() {
    #expect(OverviewSidebarPreferences.clamped(100) == 160)
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
