import TerminalCore
import Testing

/// 偽の adapter・信号源・時計は `WorktreePaneAgentStateFeedTests.swift` のものを使う。
@Suite("session (タブ) 単位の pane Agent 状態列 (設計書 §12.2)")
struct WorktreePaneAgentStateFeedSessionTests {
  @Test("states は渡された session をそのまま pane 一覧の問い合わせに使う (設計書 §12.2)")
  func statesQueryTheGivenSession() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let second = try #require(TerminalSessionKey(identity: worktree, index: 2))
    let source = SessionRecordingPaneSource()
    var iterator = makeFeed().states(
      of: second, panes: source, signals: FeedSignalSource(aliveNames: ["agent"]),
      timeSource: FeedTestClock()
    ).makeAsyncIterator()

    #expect(await iterator.next() == [])
    #expect(await source.requestedSessions == [second])
  }

  @Test("snapshots は渡された session をそのまま pane 一覧の問い合わせに使う")
  func snapshotsQueryTheGivenSession() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let second = try #require(TerminalSessionKey(identity: worktree, index: 2))
    let source = SessionRecordingPaneSource()
    var iterator = makeFeed().snapshots(
      of: second, panes: source, signals: FeedSignalSource(aliveNames: ["agent"]),
      timeSource: FeedTestClock()
    ).makeAsyncIterator()

    #expect(await iterator.next() == WorktreePaneAgentStates(panes: [], isComplete: true))
    #expect(await source.requestedSessions == [second])
  }

  @Test("worktree を渡すと番号 1 の session を問い合わせる")
  func worktreeQueriesPrimarySession() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let source = SessionRecordingPaneSource()
    var states = makeFeed().states(
      of: worktree, panes: source, signals: FeedSignalSource(aliveNames: ["agent"]),
      timeSource: FeedTestClock()
    ).makeAsyncIterator()
    var snapshots = makeFeed().snapshots(
      of: worktree, panes: source, signals: FeedSignalSource(aliveNames: ["agent"]),
      timeSource: FeedTestClock()
    ).makeAsyncIterator()

    _ = await states.next()
    _ = await snapshots.next()
    #expect(await source.requestedSessions == [.primary(worktree), .primary(worktree)])
  }

  // 今の製品コードは通らないが、`any WorktreePaneSource` 越しに worktree で呼ぶと既定実装に入る。
  @Test("protocol の既定実装の worktree 版は番号 1 の session を問い合わせる")
  func protocolWorktreeOverloadQueriesPrimarySession() async throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/test"))
    let recorder = SessionRecordingPaneSource()
    let source: any WorktreePaneSource = recorder

    _ = try await source.panes(of: worktree)
    #expect(await recorder.requestedSessions == [.primary(worktree)])
  }

  private func makeFeed() -> WorktreePaneAgentStateFeed {
    let channel = ObservationChannel()
    return WorktreePaneAgentStateFeed(
      adapters: [FeedAdapter(id: "matched", processNames: ["agent"], channel: channel)],
      fallback: FeedAdapter(id: "fallback", processNames: [], channel: channel),
      intervals: .init(signals: .seconds(1), liveness: .seconds(1)),
      paneListInterval: .seconds(1))
  }
}

/// pane が1つも無い session として振る舞い、問い合わせを受けた session を記録する。
private actor SessionRecordingPaneSource: WorktreePaneSource {
  private(set) var requestedSessions: [TerminalSessionKey] = []

  func panes(of session: TerminalSessionKey) async throws -> [PaneSnapshot] {
    requestedSessions.append(session)
    return []
  }
}
