import Foundation
import Testing

@testable import TerminalCore

@Suite("§12.7 メインpaneの登録")
struct MainPaneRegistryTests {
  private static func identity() throws -> WorktreeIdentity {
    try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
  }

  /// 計測値: 同じ server の全 pane で `#{pid}` は同じ値になる。テストでもその不変条件を守る。
  private static let serverPID: Int32 = 900

  private static func registration(
    _ id: String, processID: Int32 = 1, serverProcessID: Int32 = serverPID
  ) -> MainPaneRegistration {
    MainPaneRegistration(
      pane: PaneID(rawValue: id), processID: processID, serverProcessID: serverProcessID)
  }

  private static func pane(
    _ id: String, dead: Bool = false, processID: Int32 = 1
  ) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: id),
      processID: processID,
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
    let resolution = registry.resolve(
      for: worktree, panes: [Self.pane("%1")], serverProcessID: Self.serverPID)
    #expect(
      resolution
        == .unregistered(candidates: [MainPaneCandidate(pane: Self.pane("%1"), isAgent: false)]))
    #expect(registry.registration(for: worktree) == nil)
  }

  @Test("Agent と判定された pane も自動では選ばない (印として渡すだけ)")
  func neverAutoSelectsAgentPane() throws {
    let registry = MainPaneRegistry()
    let worktree = try Self.identity()
    let resolution = registry.resolve(
      for: worktree,
      panes: [Self.pane("%1"), Self.pane("%2")],
      serverProcessID: Self.serverPID,
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
    registry.register(Self.registration("%2"), for: worktree)
    #expect(
      registry.resolve(
        for: worktree, panes: [Self.pane("%1"), Self.pane("%2")],
        serverProcessID: Self.serverPID)
        == .registered(
          Self.registration("%2"),
          candidates: [
            MainPaneCandidate(pane: Self.pane("%1"), isAgent: false),
            MainPaneCandidate(pane: Self.pane("%2"), isAgent: false),
          ]))
  }

  @Test("選び直すと登録が置き換わる")
  func replacesSelection() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%1"), for: worktree)
    registry.register(Self.registration("%2"), for: worktree)
    #expect(registry.registration(for: worktree)?.pane == PaneID(rawValue: "%2"))
    registry.clear(for: worktree)
    #expect(registry.registration(for: worktree) == nil)
  }

  @Test("登録は worktree ごとに独立する")
  func keepsRegistrationsPerWorktree() throws {
    var registry = MainPaneRegistry()
    let first = try Self.identity()
    let second = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/other"))
    registry.register(Self.registration("%1"), for: first)
    #expect(registry.registration(for: second) == nil)
  }

  @Test("登録した pane が消えたら、別 pane へ丸めずに区別して返す", arguments: [true, false])
  func doesNotFallBackWhenRegisteredPaneIsGone(exitedInPlace: Bool) throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%2"), for: worktree)
    // 一覧から消えた場合と、dead pane として残っている場合のどちらも「存在しない」。
    let panes =
      exitedInPlace ? [Self.pane("%1"), Self.pane("%2", dead: true)] : [Self.pane("%1")]
    let resolution = registry.resolve(
      for: worktree, panes: panes, serverProcessID: Self.serverPID)
    #expect(
      resolution
        == .registeredPaneMissing(
          Self.registration("%2"), .paneGone(PaneID(rawValue: "%2")),
          candidates: [MainPaneCandidate(pane: Self.pane("%1"), isAgent: false)]))
    // 登録自体は残す。消すかどうかはユーザーの判断。
    #expect(registry.registration(for: worktree)?.pane == PaneID(rawValue: "%2"))
  }

  @Test("ID が同じでも pane_pid が違えば登録先が存在しないものとして扱う (Issue #246)")
  func treatsSamePaneIDWithDifferentProcessIDAsMissing() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%1", processID: 4242), for: worktree)
    // tmux server が落ちて session が作り直されると `%N` は 0 から振り直される (実測)。
    let resolution = registry.resolve(
      for: worktree, panes: [Self.pane("%1", processID: 5353)], serverProcessID: Self.serverPID)
    #expect(
      resolution
        == .registeredPaneMissing(
          Self.registration("%1", processID: 4242), .paneReplaced(PaneID(rawValue: "%1")),
          candidates: [
            MainPaneCandidate(pane: Self.pane("%1", processID: 5353), isAgent: false)
          ]))
  }

  @Test("server が入れ替わっていれば、pane ID も pane_pid も一致していても送信先にしない (Issue #246)")
  func treatsSamePaneAndProcessIDOnAnotherServerAsMissing() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%1", processID: 4242), for: worktree)
    // macOS の PID は 100〜99998 を連番で回すため、`%N` と `pane_pid` の同時衝突は作れる
    // (実測: 98,623 forks / 37.8 秒)。server PID まで一致しない限り送信先にしない。
    let resolution = registry.resolve(
      for: worktree, panes: [Self.pane("%1", processID: 4242)], serverProcessID: 901)
    #expect(resolution.absence == .paneReplaced(PaneID(rawValue: "%1")))
  }

  @Test("server の同一性を確かめられないときは、別 pane だと断定せず送信先にしない")
  func doesNotResolveWhenServerIdentityIsUnknown() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%1"), for: worktree)
    // `serverProcessID()` は server 不在だけでなく `#{pid}` のパース失敗でも nil を返す。
    // 「同じ ID の別 pane に置き換わっています」と説明するのは、その根拠が無い。
    let resolution = registry.resolve(
      for: worktree, panes: [Self.pane("%1")], serverProcessID: nil)
    #expect(resolution.absence == .identityUnverifiable(PaneID(rawValue: "%1")))
  }

  @Test("同一性を確かめられず、その pane も一覧に居なければ「消えた」と説明する")
  func reportsGonePaneEvenWhenServerIdentityIsUnknown() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%1"), for: worktree)
    let resolution = registry.resolve(for: worktree, panes: [], serverProcessID: nil)
    #expect(resolution.absence == .paneGone(PaneID(rawValue: "%1")))
  }

  @Test("ID ごと消えた場合と、ID は在るが別 pane の場合を区別する (picker の文面が食い違うため)")
  func distinguishesGonePaneFromReplacedPane() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%1", processID: 4242), for: worktree)
    let gone = registry.resolve(
      for: worktree, panes: [Self.pane("%2")], serverProcessID: Self.serverPID)
    let replaced = registry.resolve(
      for: worktree, panes: [Self.pane("%1", processID: 5353)], serverProcessID: Self.serverPID)
    #expect(gone.absence == .paneGone(PaneID(rawValue: "%1")))
    #expect(replaced.absence == .paneReplaced(PaneID(rawValue: "%1")))
  }

  @Test("送信できる状態では absence を立てない")
  func hasNoAbsenceWhileRegisteredPaneIsUsable() throws {
    var registry = MainPaneRegistry()
    let worktree = try Self.identity()
    registry.register(Self.registration("%1"), for: worktree)
    #expect(
      registry.resolve(for: worktree, panes: [Self.pane("%1")], serverProcessID: Self.serverPID)
        .absence == nil)
    #expect(
      MainPaneRegistry().resolve(
        for: worktree, panes: [Self.pane("%1")], serverProcessID: Self.serverPID
      ).absence == nil)
  }

  @Test("候補に終了した pane を含めない")
  func excludesDeadPanesFromCandidates() throws {
    let registry = MainPaneRegistry()
    let worktree = try Self.identity()
    let resolution = registry.resolve(
      for: worktree, panes: [Self.pane("%1", dead: true), Self.pane("%2")],
      serverProcessID: Self.serverPID)
    #expect(
      resolution
        == .unregistered(candidates: [MainPaneCandidate(pane: Self.pane("%2"), isAgent: false)]))
  }
}
