import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("Issue #537 通知元 pane の移動先探索")
struct PaneNotifierTests {
  private let root: WorktreeIdentity
  private let task: WorktreeIdentity
  private let pane = PaneID(rawValue: "%2")

  init() throws {
    root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
  }

  @Test("移動先が1つなら details または paneStates から session を返す", arguments: [true, false])
  func findsUniqueDestination(detailsOnly: Bool) throws {
    let destination = try #require(TerminalSessionKey(identity: task, index: 2))
    let observation = PaneObservationStore.Observed(
      paneStates: detailsOnly
        ? nil : [PaneAgentState(id: pane, state: .idle, lastUpdatedAt: Date())],
      details: detailsOnly ? [pane: OverviewPaneDetail()] : [:])

    #expect(
      PaneNotifier.session(
        containing: pane, in: [.primary(root): .init(), destination: observation],
        excluding: .primary(root), inventory: inventory()) == destination)
  }

  @Test("他の session に見つからなければ移動先を返さない")
  func missingDestination() {
    #expect(
      PaneNotifier.session(
        containing: pane, in: [.primary(root): containingPane, .primary(task): .init()],
        excluding: .primary(root), inventory: inventory()) == nil)
  }

  @Test("同じ worktree の別タブを含む複数 session に見つかれば推測で選ばない")
  func ambiguousDestination() throws {
    let second = try #require(TerminalSessionKey(identity: task, index: 2))

    #expect(
      PaneNotifier.session(
        containing: pane, in: [.primary(task): containingPane, second: containingPane],
        excluding: .primary(root), inventory: inventory()) == nil)
  }

  @Test("観測対象外の session は移動先にも曖昧さの判定にも含めない", arguments: [true, false])
  func ignoresUnobservableSessions(hasObservableDestination: Bool) throws {
    let source = try #require(TerminalSessionKey(identity: root, index: 2))
    var observed: [TerminalSessionKey: PaneObservationStore.Observed] = [
      .primary(task): containingPane
    ]
    if hasObservableDestination { observed[.primary(root)] = containingPane }

    #expect(
      PaneNotifier.session(
        containing: pane, in: observed, excluding: source,
        inventory: inventory(activation: .inactive))
        == (hasObservableDestination ? .primary(root) : nil))
  }

  private var containingPane: PaneObservationStore.Observed {
    .init(details: [pane: OverviewPaneDetail()])
  }

  private func inventory(activation: WorktreeActivation = .active) -> WorktreeInventory {
    WorktreeInventory(
      projectRoot: DetectedWorktree(
        identity: root, worktreePath: "/repo", branch: "main", isProjectRoot: true),
      taskWorktrees: [
        TaskWorktree(
          detected: DetectedWorktree(
            identity: task, worktreePath: "/repo-task", branch: "task", isProjectRoot: false),
          activation: activation)
      ])
  }
}
