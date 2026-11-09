import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("Issue #387 初回の観測完了")
struct PaneObservationStoreTests {
  // 配信された Completed の時刻 (10) でも Working の観測時刻 (20) でもなく、Working が運ぶ
  // 応答終了の最終観測時刻 (16) で判定することを、その前後に始まったターンで固定する。
  @Test(
    "Issue #386 Working が運ぶ応答終了の最終観測時刻より前のターンの完了だけを解除する",
    arguments: [(11_000, false), (17_000, true)])
  func dismissesCompletionAfterObservedTurnEnd(
    turnStartMilliseconds: Int, remainsCompleted: Bool
  ) async throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let session = TerminalSessionKey.primary(identity)
    let states = AsyncStream<WorktreePaneAgentStates>.makeStream()
    let summaryGate = AsyncStream<Void>.makeStream()
    defer {
      states.continuation.finish()
      summaryGate.continuation.finish()
    }
    let processRunner = CompletionObservationRunner(
      sessionName: TmuxSessionName(key: session).rawValue, summaryGate: summaryGate.stream,
      turnStartMilliseconds: turnStartMilliseconds)
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let runner = try TmuxRunner(
      server: .userDefault, processRunner: processRunner, executableCandidates: [executable])
    let store = PaneObservationStore(
      dependencies: AppDependencies(
        launchProject: .none, tmuxExecutable: executable, tmuxError: nil,
        paneStates: { _ in states.stream }, tmuxRunner: runner,
        paneSource: TmuxWorktreePaneSource(runner: runner),
        signalSource: TmuxAgentSignalSource(tmuxRunner: runner, processRunner: processRunner),
        sessionActivityProbe: nil, applicationSupportDirectory: nil, applicationSupportWarning: nil),
      notifier: nil)
    defer { store.stopAll() }
    store.observe(
      WorktreeInventory(
        projectRoot: DetectedWorktree(
          identity: identity, worktreePath: "/repo", branch: "main", isProjectRoot: true),
        taskWorktrees: []), sessions: [session])
    let pane = PaneID(rawValue: "%2")
    let firstTurnEnd = Date(timeIntervalSince1970: 10)
    let completed = PaneAgentState(
      id: pane,
      observation: AgentStateObservation(
        state: .completed, adapterID: AgentAdapterID(rawValue: "test"), observedAt: firstTurnEnd,
        lastTurnEndObservedAt: firstTurnEnd))
    states.continuation.yield(.init(panes: [completed], isComplete: true))
    try await waitUntil { store.observed[session]?.latestPaneStates == [completed] }
    #expect(store.observed[session]?.details[pane]?.isTaskCompleted == false)

    summaryGate.continuation.finish()
    try await waitUntil { store.observed[session]?.details[pane]?.isTaskCompleted == true }
    #expect(store.observed[session]?.details[pane]?.isTaskCompleted == true)

    let working = PaneAgentState(
      id: pane,
      observation: AgentStateObservation(
        state: .working, adapterID: AgentAdapterID(rawValue: "test"),
        observedAt: Date(timeIntervalSince1970: 20),
        lastTurnEndObservedAt: Date(timeIntervalSince1970: 16)))
    states.continuation.yield(.init(panes: [working], isComplete: true))
    try await waitUntil { store.observed[session]?.latestPaneStates == [working] }
    #expect(store.observed[session]?.details[pane]?.isTaskCompleted == remainsCompleted)
  }

  @Test("Issue #661 worktree の観測を停止して再開すると初回完了を引き継がない")
  func resetsCompletedObservationAfterRestart() async throws {
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let rootSession = TerminalSessionKey.primary(root)
    let session = TerminalSessionKey.primary(identity)
    let feeds = AsyncStream<AsyncStream<WorktreePaneAgentStates>.Continuation>.makeStream()
    defer { feeds.continuation.finish() }
    let store = PaneObservationStore(
      dependencies: AppDependencies(
        launchProject: .none, tmuxExecutable: nil, tmuxError: nil,
        paneStates: { key in
          let states = AsyncStream<WorktreePaneAgentStates>.makeStream()
          if key == session { feeds.continuation.yield(states.continuation) }
          return states.stream
        }, tmuxRunner: nil, paneSource: nil, signalSource: nil,
        sessionActivityProbe: nil, applicationSupportDirectory: nil, applicationSupportWarning: nil),
      notifier: nil)
    defer { store.stopAll() }
    let inventory = WorktreeInventory(
      projectRoot: DetectedWorktree(
        identity: root, worktreePath: "/repo", branch: "main", isProjectRoot: true),
      taskWorktrees: [
        TaskWorktree(
          detected: DetectedWorktree(
            identity: identity, worktreePath: "/repo/task", branch: "task", isProjectRoot: false),
          activation: .active)
      ])
    var iterator = feeds.stream.makeAsyncIterator()
    store.observe(inventory, sessions: [rootSession, session])
    let firstFeed = try #require(await iterator.next())
    defer { firstFeed.finish() }
    firstFeed.yield(.init(panes: [paneState], isComplete: true))
    try await waitUntil { store.observed[session]?.paneStates != nil }
    #expect(store.observed[session]?.paneStates == [paneState])

    store.observe(inventory, sessions: [rootSession])
    #expect(store.observed[session] == nil)
    store.observe(inventory, sessions: [rootSession, session])
    let restartedFeed = try #require(await iterator.next())
    defer { restartedFeed.finish() }
    #expect(store.observed[session]?.paneStates == nil)

    restartedFeed.yield(.init(panes: [], isComplete: false))
    restartedFeed.yield(.init(panes: [paneState], isComplete: false))
    try await waitUntil { store.observed[session]?.latestPaneStates == [paneState] }
    #expect(store.observed[session] != nil)
    #expect(store.observed[session]?.paneStates == nil)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
  }

  @Test("未完の snapshot だけでは未観測のまま", arguments: [true, false])
  func incompleteObservation(isEmpty: Bool) throws {
    var observation = PaneObservationStore.Observed()
    let panes = isEmpty ? [] : [paneState]
    for _ in 0..<2 {
      observation.receivePaneStates(.init(panes: panes, isComplete: false))
      #expect(observation.paneStates == nil)
      #expect(observation.latestPaneStates == panes)
      let input = try input(observation)
      #expect(!input.isObserved)
      #expect(makeTabSummaries([input]).first?.rows == [.notObserved])
    }
  }

  @Test("初回完了後は未完の snapshot でも観測済みのまま")
  func completedObservation() throws {
    var observation = PaneObservationStore.Observed()
    observation.receivePaneStates(.init(panes: [], isComplete: false))
    observation.receivePaneStates(.init(panes: [], isComplete: true))

    #expect(try input(observation).isObserved)
    #expect(observation.paneStates == [])
    #expect(makeTabSummaries([try input(observation)]).first?.rows == [.noAgentPane])

    observation.receivePaneStates(.init(panes: [paneState], isComplete: false))

    #expect(try input(observation).isObserved)
    #expect(observation.paneStates == [paneState])
    #expect(observation.latestPaneStates == [paneState])
  }

  @Test("観測を作り直した session と別 session は初回完了を引き継がない")
  func freshObservation() throws {
    var observation = PaneObservationStore.Observed()
    observation.receivePaneStates(.init(panes: [], isComplete: true))
    #expect(try input(observation).isObserved)

    var other = PaneObservationStore.Observed()
    other.receivePaneStates(.init(panes: [], isComplete: false))
    #expect(try !input(other).isObserved)

    observation = PaneObservationStore.Observed()
    observation.receivePaneStates(.init(panes: [], isComplete: false))
    #expect(try !input(observation).isObserved)
  }

  private var paneState: PaneAgentState {
    PaneAgentState(id: PaneID(rawValue: "%2"), state: .working, lastUpdatedAt: .distantPast)
  }

  private func input(_ observation: PaneObservationStore.Observed) throws -> OverviewWorktreeInput {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    return OverviewWorktreeInput(
      session: .primary(identity), observation: observation, mainPane: nil)
  }
}

private struct CompletionObservationRunner: ProcessRunning {
  let sessionName: String
  let summaryGate: AsyncStream<Void>
  let turnStartMilliseconds: Int

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    if arguments.contains("list-panes") {
      for await _ in summaryGate {}
      let fields = [
        "%2", sessionName, "0", "@1", "0", "100", "1", "codex", "0", "", "",
        "/dev/ttys002", "/repo", "", "v", "v200 turn=\(turnStartMilliseconds) done", "v",
      ]
      return .init(exitCode: 0, stdout: fields.joined(separator: "\u{1F}") + "\n", stderr: "")
    }
    return .init(exitCode: 0, stdout: "100 1 zsh\n200 100 codex\n", stderr: "")
  }
}
