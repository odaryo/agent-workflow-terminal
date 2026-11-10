import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("§3.3 復元したセッションの作成確認")
struct RestoredSessionTests {
  @Test("保存が読めた起動だけ全セッションに印を付ける", arguments: [true, false], [true, false])
  func marksInitialSessions(hasSavedInventory: Bool, hasSessionNames: Bool) throws {
    let model = try makeModel()
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let inactive = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/inactive"))
    let second = try #require(TerminalSessionKey(identity: task, index: 2))
    let result = WorktreeScanResult(
      inventory: WorktreeInventory(
        projectRoot: detected(root, isProjectRoot: true),
        taskWorktrees: [
          TaskWorktree(detected: detected(task), activation: .active),
          TaskWorktree(detected: detected(inactive), activation: .inactive),
        ]),
      appeared: [], disappeared: [])

    model.applyInitial(
      result,
      sessionNames: hasSessionNames
        ? [TmuxSessionName(key: .primary(task)).rawValue, TmuxSessionName(key: second).rawValue]
        : nil,
      hasSavedInventory: hasSavedInventory)

    var expected: Set<TerminalSessionKey> = [.primary(root), .primary(task)]
    if hasSessionNames { expected.insert(second) }
    #expect(Set(model.sessionKeys) == expected)
    #expect(model.restoredSessions == (hasSavedInventory ? expected : []))
    #expect(model.displayedSession == .primary(root))
  }

  @Test("復元セッションは tmux session が無いか不明なら確認し、存在すれば開く", arguments: [true, false, nil])
  func restoredOpening(sessionExists: Bool?) async throws {
    let model = try makeModel(sessionExists: sessionExists)
    let key = try #require(model.sessionKeys.first)

    #expect(await model.shouldOpenSession(key) == (sessionExists == true ? .open : .offerCreate))
    #expect(model.sessionKeys.contains(key))
    #expect(model.restoredSessions.contains(key))
  }

  @Test("保存の無い起動は session が無くても開く")
  func opensWithoutSavedInventory() async throws {
    let model = try makeModel(hasSavedInventory: false)
    let key = try #require(model.sessionKeys.first)

    #expect(await model.shouldOpenSession(key) == .open)
  }

  @Test("作成承認後は確認を繰り返さない")
  func approvalClearsRestoration() async throws {
    let model = try makeModel()
    let key = try #require(model.sessionKeys.first)
    #expect(await model.shouldOpenSession(key) == .offerCreate)

    model.approveSessionCreation(key)

    #expect(!model.restoredSessions.contains(key))
    #expect(await model.shouldOpenSession(key) == .open)
  }

  @Test("準備成功後の再 attach では再確認しない")
  func preparationClearsRestoration() async throws {
    let model = try makeModel()
    let key = try #require(model.sessionKeys.first)
    model.newlyAddedSessions.insert(key)

    model.didPrepareSession(key)

    #expect(!model.restoredSessions.contains(key))
    #expect(!model.newlyAddedSessions.contains(key))
    #expect(await model.shouldOpenSession(key) == .open)
  }

  @Test("同じディレクトリに他のセッションがあれば、tmux session が無い復元セッションを閉じる")
  func closesMissingSessionWithNeighbor() async throws {
    let model = try makeModel()
    let key = try #require(model.sessionKeys.first)
    model.selectNewSession(in: key.identity, existingSessionNames: [])
    let neighbor = try #require(model.displayedSession)

    #expect(await model.shouldOpenSession(neighbor) == .open)
    #expect(await model.shouldOpenSession(key) == .close)
    #expect(!model.sessionKeys.contains(key))
    #expect(!model.restoredSessions.contains(key))
    #expect(model.displayedSession == neighbor)
    #expect(model.warning?.contains("外部で終了していたため、セッションを閉じました") == true)
  }

  @Test("セッション削除は新規と復元の印を両方外す", arguments: [true, false])
  func removalClearsMarks(discard: Bool) throws {
    let model = try makeModel()
    let key = try #require(model.sessionKeys.first)
    model.selectNewSession(in: key.identity, existingSessionNames: [])
    model.newlyAddedSessions.insert(key)

    if discard {
      model.discardSession(key)
    } else {
      model.removeSession(key)
    }

    #expect(!model.restoredSessions.contains(key))
    #expect(!model.newlyAddedSessions.contains(key))
  }

  @Test("ディレクトリのセッション削除は他のディレクトリの印を残す")
  func directoryRemovalClearsOnlyMatchingMarks() throws {
    let model = try makeModel()
    let key = try #require(model.sessionKeys.first)
    let other = TerminalSessionKey.primary(
      try #require(WorktreeIdentity(rawValue: "/other/.git")))
    model.restoredSessions.insert(other)
    model.newlyAddedSessions = [key, other]
    model.pendingAgentCommands = [key: "agent", other: "other-agent"]

    model.removeSessions(in: key.identity)

    #expect(model.restoredSessions == [other])
    #expect(model.newlyAddedSessions == [other])
    #expect(model.consumeAgentCommand(for: key) == nil)
    #expect(model.consumeAgentCommand(for: other) == "other-agent")
  }

  @Test("明示的な Active 化では復元の印を残さない")
  func activationClearsRestoration() throws {
    let model = try makeModel()
    let root = try #require(model.projectRoot)
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    model.applyInitial(
      WorktreeScanResult(
        inventory: WorktreeInventory(
          projectRoot: root,
          taskWorktrees: [TaskWorktree(detected: detected(identity), activation: .active)]),
        appeared: [], disappeared: []),
      sessionNames: nil, hasSavedInventory: true)
    #expect(model.restoredSessions.contains(.primary(identity)))

    model.setActivation(.inactive, of: identity)
    model.setActivation(.active, of: identity)

    #expect(!model.restoredSessions.contains(.primary(identity)))
    #expect(model.restoredSessions.contains(.primary(root.identity)))
  }

  @Test("Agent 起動予約は追加したセッションだけに付き、1回で消費する")
  func consumesAgentCommandOnce() throws {
    let model = try makeModel()
    let original = try #require(model.sessionKeys.first)
    model.selectNewSession(
      in: original.identity, existingSessionNames: [], agentCommand: "agent --resume")
    let added = try #require(model.displayedSession)

    #expect(added != original)
    #expect(model.consumeAgentCommand(for: original) == nil)
    #expect(model.consumeAgentCommand(for: added) == "agent --resume")
    #expect(model.consumeAgentCommand(for: added) == nil)
  }

  @Test("セッションを削除・破棄・準備完了にすると Agent 起動予約も消す", arguments: [0, 1, 2, 3])
  func clearsAgentCommand(action: Int) throws {
    let model = try makeModel()
    let original = try #require(model.sessionKeys.first)
    model.selectNewSession(
      in: original.identity, existingSessionNames: [], agentCommand: "agent")
    let added = try #require(model.displayedSession)
    switch action {
    case 0: model.removeSession(added)
    case 1: model.discardSession(added)
    case 2: model.removeSessions(in: added.identity)
    default: model.didPrepareSession(added)
    }
    #expect(model.consumeAgentCommand(for: added) == nil)
  }

  @Test("通常の追加と追加不可の操作は Agent 起動を予約しない")
  func doesNotReserveForUnaddedSession() throws {
    let model = try makeModel()
    let original = try #require(model.sessionKeys.first)
    model.selectNewSession(in: original.identity, existingSessionNames: [])
    let added = try #require(model.displayedSession)
    #expect(model.consumeAgentCommand(for: added) == nil)

    let unknown = try #require(WorktreeIdentity(rawValue: "/unknown/.git"))
    model.selectNewSession(in: unknown, existingSessionNames: [], agentCommand: "agent")
    #expect(model.pendingAgentCommands.isEmpty)
  }

  private func detected(
    _ identity: WorktreeIdentity, isProjectRoot: Bool = false
  ) -> DetectedWorktree {
    DetectedWorktree(
      identity: identity, worktreePath: "/repo", branch: "main", isProjectRoot: isProjectRoot)
  }

  private func makeModel(
    sessionExists: Bool? = false, hasSavedInventory: Bool = true
  ) throws -> AppModel {
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let runner = try TmuxRunner(
      server: .userDefault, processRunner: SessionExistenceRunner(exists: sessionExists),
      executableCandidates: [executable])
    let model = AppModel(
      project: RegisteredProject(commonDirectory: root, directory: "/repo"),
      dependencies: AppDependencies(
        launchProject: .none, tmuxExecutable: executable, tmuxError: nil,
        paneStates: nil, tmuxRunner: runner, paneSource: nil, signalSource: nil,
        sessionActivityProbe: nil, applicationSupportDirectory: nil, applicationSupportWarning: nil),
      notifier: nil)
    model.applyInitial(
      WorktreeScanResult(
        inventory: WorktreeInventory(
          projectRoot: detected(root, isProjectRoot: true), taskWorktrees: []),
        appeared: [], disappeared: []),
      sessionNames: nil, hasSavedInventory: hasSavedInventory)
    return model
  }
}

private struct SessionExistenceRunner: ProcessRunning {
  let exists: Bool?

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    // Swift 6.1 (CI) は `Bool?` の `true` / `false` / `nil` の switch を網羅と認めない。
    guard let exists else { return .init(exitCode: 1, stdout: "", stderr: "permission denied\n") }
    return exists
      ? .init(exitCode: 0, stdout: "", stderr: "")
      : .init(exitCode: 1, stdout: "", stderr: "no server running on /tmp/awt-test\n")
  }
}
