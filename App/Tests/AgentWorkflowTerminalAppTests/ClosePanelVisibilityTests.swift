import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

struct ClosePanelVisibilityTests {
  @Test("§3.4 対象の worktree を表示している間だけ Close を出す")
  func worktreeCloseFollowsDirectory() throws {
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let second = try #require(TerminalSessionKey(identity: task, index: 2))
    let keys: [TerminalSessionKey] = [second, .primary(root)]

    #expect(ClosePanelVisibility.showsWorktreeClose(for: task, selected: task, sessionKeys: keys))
    #expect(!ClosePanelVisibility.showsWorktreeClose(for: task, selected: root, sessionKeys: keys))
    #expect(!ClosePanelVisibility.showsWorktreeClose(for: task, selected: nil, sessionKeys: keys))
  }

  @Test("§3.4 対象の worktree にセッションが無ければ Close の結果を出す")
  func worktreeCloseOutlivesSessions() throws {
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))

    #expect(
      ClosePanelVisibility.showsWorktreeClose(
        for: task, selected: root, sessionKeys: [.primary(root)]))
    #expect(ClosePanelVisibility.showsWorktreeClose(for: task, selected: nil, sessionKeys: []))
  }

  @Test("§3.1 セッションを閉じる確認は対象のセッションだけに出す")
  func sessionCloseFollowsExactSession() throws {
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let target = TerminalSessionKey.primary(task)
    let second = try #require(TerminalSessionKey(identity: task, index: 2))

    #expect(ClosePanelVisibility.showsSessionClose(for: target, displayed: target))
    #expect(!ClosePanelVisibility.showsSessionClose(for: target, displayed: second))
    #expect(!ClosePanelVisibility.showsSessionClose(for: target, displayed: .primary(root)))
    #expect(!ClosePanelVisibility.showsSessionClose(for: target, displayed: nil))
  }
}
