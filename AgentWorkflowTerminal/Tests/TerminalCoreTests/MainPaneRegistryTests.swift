import Foundation
import Testing

@testable import TerminalCore

@Suite("§12.7 メインpaneの登録")
struct MainPaneRegistryTests {
  private static func identity() throws -> WorktreeIdentity {
    try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
  }

  private static func pane(_ id: String, dead: Bool = false) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: id),
      processID: 1,
      tty: "/dev/ttys001",
      currentCommand: "zsh",
      currentPath: "/repo",
      title: "title",
      termination: dead ? .unknown : nil)
  }

  @Test("候補が1つでも自動では選ばない")
  func neverAutoSelectsSingleCandidate() throws {
    let registry = MainPaneRegistry()
    let worktree = try Self.identity()
    let resolution = registry.resolve(for: worktree, panes: [Self.pane("%1")])
    #expect(
      resolution
        == .unregistered(candidates: [MainPaneCandidate(pane: Self.pane("%1"), isAgent: false)]))
    #expect(registry.registeredPane(for: worktree) == nil)
  }

  @Test("Agent と判定された pane も自動では選ばない (印として渡すだけ)")
  func neverAutoSelectsAgentPane() throws {
    let registry = MainPaneRegistry()
    let worktree = try Self.identity()
    let resolution = registry.resolve(
      for: worktree,
      panes: [Self.pane("%1"), Self.pane("%2")],
      agentPaneIDs: [PaneID(rawValue: "%2")])
    guard case .unregistered(let candidates) = resolution else {
      Issue.record("未登録のはずが \(resolution)")
      return
    }
    #expect(candidates.map(\.id) == [PaneID(rawValue: "%1"), PaneID(rawValue: "%2")])
    #expect(candidates.map(\.isAgent) == [false, true])
  }

  @Test("ユーザーが選んだ pane を記憶し、以後の既定の送信先にする")
  func remembersUserSelection() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(PaneID(rawValue: "%2"), for: worktree)
    #expect(
      registry.resolve(for: worktree, panes: [Self.pane("%1"), Self.pane("%2")])
        == .registered(
          PaneID(rawValue: "%2"),
          candidates: [
            MainPaneCandidate(pane: Self.pane("%1"), isAgent: false),
            MainPaneCandidate(pane: Self.pane("%2"), isAgent: false),
          ]))
  }

  @Test("選び直すと登録が置き換わる")
  func replacesSelection() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(PaneID(rawValue: "%1"), for: worktree)
    registry.register(PaneID(rawValue: "%2"), for: worktree)
    #expect(registry.registeredPane(for: worktree) == PaneID(rawValue: "%2"))
    registry.clear(for: worktree)
    #expect(registry.registeredPane(for: worktree) == nil)
  }

  @Test("登録は worktree ごとに独立する")
  func keepsRegistrationsPerWorktree() throws {
    var registry = MainPaneRegistry()
    let first = try Self.identity()
    let second = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/other"))
    registry.register(PaneID(rawValue: "%1"), for: first)
    #expect(registry.registeredPane(for: second) == nil)
  }

  @Test("登録した pane が消えたら、別 pane へ丸めずに区別して返す", arguments: [true, false])
  func doesNotFallBackWhenRegisteredPaneIsGone(exitedInPlace: Bool) throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(PaneID(rawValue: "%2"), for: worktree)
    // 一覧から消えた場合と、dead pane として残っている場合のどちらも「存在しない」。
    let panes =
      exitedInPlace ? [Self.pane("%1"), Self.pane("%2", dead: true)] : [Self.pane("%1")]
    let resolution = registry.resolve(for: worktree, panes: panes)
    #expect(
      resolution
        == .registeredPaneMissing(
          PaneID(rawValue: "%2"),
          candidates: [MainPaneCandidate(pane: Self.pane("%1"), isAgent: false)]))
    // 登録自体は残す。消すかどうかはユーザーの判断。
    #expect(registry.registeredPane(for: worktree) == PaneID(rawValue: "%2"))
  }

  @Test("候補に終了した pane を含めない")
  func excludesDeadPanesFromCandidates() throws {
    let registry = MainPaneRegistry()
    let worktree = try Self.identity()
    let resolution = registry.resolve(
      for: worktree, panes: [Self.pane("%1", dead: true), Self.pane("%2")])
    #expect(
      resolution
        == .unregistered(candidates: [MainPaneCandidate(pane: Self.pane("%2"), isAgent: false)]))
  }
}
