import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("タブの巡回")
struct TabCycleTests {
  private let first = WorktreeIdentity(rawValue: "/repo/.git").map(TerminalSessionKey.primary)
  private let second = WorktreeIdentity(rawValue: "/repo/.git/worktrees/second").map(
    TerminalSessionKey.primary)
  private let third = WorktreeIdentity(rawValue: "/repo/.git/worktrees/third").map(
    TerminalSessionKey.primary)
  private let missing = WorktreeIdentity(rawValue: "/repo/.git/worktrees/missing").map(
    TerminalSessionKey.primary)

  @Test("前後の隣接タブへ移動する", arguments: [true, false])
  func adjacent(forward: Bool) throws {
    let order = try [#require(first), #require(second), #require(third)]
    #expect(
      TabCycle.adjacent(in: order, from: second, forward: forward)
        == (forward ? third : first))
  }

  @Test("両端から反対側へ巡回する", arguments: [true, false])
  func wraps(forward: Bool) throws {
    let order = try [#require(first), #require(second), #require(third)]
    #expect(
      TabCycle.adjacent(in: order, from: forward ? third : first, forward: forward)
        == (forward ? first : third))
  }

  @Test("未選択または一覧外なら進行方向の端を選ぶ", arguments: [true, false], [true, false])
  func absentCurrent(forward: Bool, isNil: Bool) throws {
    let order = try [#require(first), #require(second), #require(third)]
    let current = isNil ? nil : missing
    #expect(
      TabCycle.adjacent(in: order, from: current, forward: forward)
        == (forward ? first : third))
  }

  @Test("空の一覧では選択しない", arguments: [true, false])
  func empty(forward: Bool) {
    #expect(TabCycle.adjacent(in: [], from: nil, forward: forward) == nil)
    #expect(TabCycle.adjacent(in: [], from: first, forward: forward) == nil)
  }

  @Test("1要素なら現在の選択によらずそのタブを返す", arguments: [true, false])
  func single(forward: Bool) throws {
    let identity = try #require(first)
    for current in [nil, first, missing] {
      #expect(TabCycle.adjacent(in: [identity], from: current, forward: forward) == identity)
    }
  }
}
