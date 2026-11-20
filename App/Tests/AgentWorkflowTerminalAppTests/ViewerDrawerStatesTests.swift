import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

struct ViewerDrawerStatesTests {
  @Test("§6.1 ディレクトリごとに Drawer を開閉する")
  func independentContents() throws {
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    var states = ViewerDrawerStates()
    var layout = states.layout(for: root)
    layout.open(.diff)
    states.update(layout, for: root)
    #expect(!states.layout(for: task).isOpen)

    layout = states.layout(for: task)
    layout.open(.code)
    states.update(layout, for: task)
    #expect(states.layout(for: root).content == .diff)

    layout = states.layout(for: root)
    layout.close()
    states.update(layout, for: root)
    #expect(!states.layout(for: root).isOpen)
    #expect(states.layout(for: task).content == .code)
  }

  @Test("§6.1 同じディレクトリのセッションは Drawer を共有する")
  func sessionsShareContent() throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let first = TerminalSessionKey.primary(identity)
    let second = try #require(TerminalSessionKey(identity: identity, index: 2))
    var states = ViewerDrawerStates()
    var layout = states.layout(for: first.identity)
    layout.open(.code)
    states.update(layout, for: first.identity)
    #expect(states.layout(for: second.identity).content == .code)
  }

  @Test("§6.1 セッション未選択の更新は並びだけを反映する")
  func updateWithoutSelection() throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    var states = ViewerDrawerStates()
    var layout = states.layout(for: identity)
    layout.open(.code)
    states.update(layout, for: identity)

    layout = states.layout(for: nil)
    #expect(!layout.isOpen)
    layout.open(.diff)
    layout.setArrangement(.sideBySide, for: .diff)
    states.update(layout, for: nil)

    #expect(!states.layout(for: nil).isOpen)
    #expect(states.layout(for: identity).content == .code)
    #expect(states.layout(for: identity).arrangements == layout.arrangements)
  }

  @Test("§6.1 並びはすべてのディレクトリで共有する")
  func sharedArrangements() throws {
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    var states = ViewerDrawerStates()
    var layout = states.layout(for: root)
    layout.setArrangement(.stacked, for: .code)
    layout.setArrangement(.sideBySide, for: .diff)
    states.update(layout, for: root)
    #expect(states.layout(for: task).arrangements == layout.arrangements)
    #expect(states.layout(for: nil).arrangements == layout.arrangements)
  }

  @Test("§6.1 一覧から消えたディレクトリの中身だけを捨てる")
  func discardMissingContents() throws {
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    var states = ViewerDrawerStates()
    var layout = states.layout(for: root)
    layout.open(.code)
    states.update(layout, for: root)
    layout.open(.diff)
    layout.setArrangement(.sideBySide, for: .diff)
    states.update(layout, for: task)

    states.retainContents(for: [root])

    #expect(states.layout(for: root).content == .code)
    #expect(!states.layout(for: task).isOpen)
    #expect(states.layout(for: task).arrangements == layout.arrangements)
  }
}
