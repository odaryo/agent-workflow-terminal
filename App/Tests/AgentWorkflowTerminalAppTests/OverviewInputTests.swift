import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("Issue #387 Overview の観測入力")
struct OverviewInputTests {
  private let identity: WorktreeIdentity
  private let pane = PaneID(rawValue: "%2")

  init() throws {
    identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
  }

  @Test("観測結果が無いか初回配信待ちなら未観測の行を残す", arguments: [true, false])
  func pendingObservation(isMissing: Bool) throws {
    let input = OverviewWorktreeInput(
      session: .primary(identity), observation: isMissing ? nil : .init(), mainPane: nil)

    #expect(!input.isObserved)
    #expect(input.paneStates.isEmpty)
    let project = try #require(
      makeAgentPaneOverview([
        OverviewProjectInput(project: identity, projectRootSessions: [], tasks: [input])
      ]).first)
    let task = try #require(project.tasks.first)
    #expect(task.session == input.session)
    #expect(task.rows == [.notObserved])
    #expect(makeTabSummaries([input]).first?.rows == [.notObserved])
  }

  @Test("空配列の配信を受けたら Agent pane なしにする")
  func observedEmpty() {
    let input = OverviewWorktreeInput(
      session: .primary(identity), observation: .init(paneStates: []), mainPane: nil)

    #expect(input.isObserved)
    #expect(makeTabSummaries([input]).first?.rows == [.noAgentPane])
  }

  @Test("初出の時刻と詳細とメイン pane をそのまま渡す")
  func observedPane() throws {
    let display = PaneDisplayState(
      paneID: pane, state: .working, category: .working, changedAt: nil)
    let detail = OverviewPaneDetail(purpose: "実装")
    let input = OverviewWorktreeInput(
      session: .primary(identity),
      observation: .init(
        paneStates: [PaneAgentState(id: pane, state: .working, lastUpdatedAt: Date())],
        displayStates: [display], details: [pane: detail]),
      mainPane: pane)

    #expect(input.isObserved)
    #expect(input.paneStates == [display])
    #expect(input.details == [pane: detail])
    #expect(input.mainPane == pane)
    let row = try #require(makeTabSummaries([input]).first?.rows.first?.pane)
    #expect(row.display.changedAt == nil)
    #expect(row.isMain)
  }

  @Test("消えた pane の表示を保持中に詳細が消えても pane ID で行を表示できる")
  func retainedPaneWithoutDetails() throws {
    let instant = ContinuousClock().now
    var stabilizer = PaneDisplayStateStabilizer()
    let initial = stabilizer.observe(
      [PaneAgentState(id: pane, state: .working, lastUpdatedAt: Date())], at: instant)
    let retained = stabilizer.observe([], at: instant.advanced(by: .seconds(1)))
    let input = OverviewWorktreeInput(
      session: .primary(identity),
      observation: .init(paneStates: [], displayStates: retained), mainPane: nil)

    #expect(input.isObserved)
    #expect(input.paneStates == initial)
    let row = try #require(makeTabSummaries([input]).first?.rows.first?.pane)
    #expect(row.paneID == pane)
    #expect(row.detail == OverviewPaneDetail())
    #expect(row.detail.location == nil)
    #expect(
      paneShortName(paneID: row.paneID, isMain: row.isMain, location: row.detail.location) == "%2")
  }
}
