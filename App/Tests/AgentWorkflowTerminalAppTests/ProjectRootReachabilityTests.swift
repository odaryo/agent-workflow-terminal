import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("#310 Project Root の到達可能性")
struct ProjectRootReachabilityTests {
  @Test(
    "到達を確認できない Root は選択・新規作成・巡回の対象にしない",
    arguments: [WorktreeObservation.unreachable, .observationFailed])
  func excludesUnavailableRoot(observation: WorktreeObservation) async throws {
    let runner = RootSessionRunner()
    let model = try makeModel(rootObservation: observation, hasTask: true, runner: runner)
    let root = try #require(model.projectRoot)
    let task = try #require(model.worktrees.first)
    let keys = model.sessionKeys

    #expect(!model.canOpenSession(in: root.identity))
    #expect(model.displayedSession == .primary(task.identity))
    model.selectProjectRoot()
    #expect(model.displayedSession == .primary(task.identity))
    await model.openNewSession(in: root.identity)

    #expect(model.sessionKeys == keys)
    #expect(model.newlyAddedSessions.isEmpty)
    #expect(await runner.callCount == 0)
    #expect(model.sessionCycleOrder == [.primary(task.identity)])
  }

  @Test(
    "scan 失敗時、Root のディレクトリに入れなければ選択を外す",
    arguments: [true, false])
  func marksMissingRoot(hasTask: Bool) throws {
    let model = try makeModel(hasTask: hasTask)
    let root = try #require(model.projectRoot)
    let worktrees = model.worktrees
    let keys = model.sessionKeys
    #expect(model.displayedSession == .primary(root.identity))

    model.reconcileFailedScan { path in
      #expect(path == root.worktreePath)
      return false
    }

    #expect(model.projectRoot?.observation == .unreachable)
    #expect(model.projectRoot?.identity == root.identity)
    #expect(model.worktrees == worktrees)
    #expect(model.sessionKeys == keys)
    #expect(!model.canOpenSession(in: root.identity))
    #expect(model.displayedSession == worktrees.first.map { .primary($0.identity) })
    #expect(model.pendingSave == nil)
  }

  @Test(
    "scan 失敗でも Root のディレクトリに入れるなら状態と選択を維持する",
    arguments: [WorktreeObservation.reachable, .unreachable, .observationFailed])
  func preservesRootOnTransientFailure(observation: WorktreeObservation) throws {
    let model = try makeModel(rootObservation: observation)
    let inventory = model.inventory
    let selection = model.displayedSession
    let opened = model.openedSessions

    model.reconcileFailedScan(isDirectoryReachable: { _ in true })

    #expect(model.inventory == inventory)
    #expect(model.displayedSession == selection)
    #expect(model.openedSessions == opened)
    #expect(model.pendingSave == nil)
  }

  @Test("Root が回復し選択が nil なら選び直す")
  func selectsRecoveredRoot() throws {
    let model = try makeModel()
    let root = try #require(model.projectRoot)
    // 回復した観測の適用後も、直前の到達不能で選択が外れた状態を再現する。
    model.displayedSession = nil

    model.reconcileSessionSelection()

    #expect(model.displayedSession == .primary(root.identity))
  }

  @Test("Root を選べなくても選択が nil なら到達可能な Task を選ぶ")
  func selectsTaskWithoutSelection() throws {
    let model = try makeModel(rootObservation: .unreachable, hasTask: true)
    let task = try #require(model.worktrees.first)
    model.displayedSession = nil

    model.reconcileSessionSelection()

    #expect(model.displayedSession == .primary(task.identity))
  }

  private func makeModel(
    rootObservation: WorktreeObservation = .reachable, hasTask: Bool = false,
    runner: RootSessionRunner = RootSessionRunner()
  ) throws -> AppModel {
    let root = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let task = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/task"))
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let tmuxRunner = try TmuxRunner(
      server: .userDefault, processRunner: runner, executableCandidates: [executable])
    let model = AppModel(
      project: RegisteredProject(commonDirectory: root, directory: "/repo"),
      dependencies: AppDependencies(
        launchProject: .none, tmuxExecutable: executable, tmuxError: nil,
        paneStates: nil, tmuxRunner: tmuxRunner, paneSource: nil, signalSource: nil,
        sessionActivityProbe: nil, applicationSupportDirectory: nil, applicationSupportWarning: nil),
      notifier: nil)
    model.applyInitial(
      WorktreeScanResult(
        inventory: WorktreeInventory(
          projectRoot: DetectedWorktree(
            identity: root, worktreePath: "/repo", branch: "main", isProjectRoot: true,
            observation: rootObservation),
          taskWorktrees: hasTask
            ? [
              TaskWorktree(
                detected: DetectedWorktree(
                  identity: task, worktreePath: "/task", branch: "task", isProjectRoot: false),
                activation: .active)
            ] : []),
        appeared: [], disappeared: []),
      sessionNames: nil, hasSavedInventory: false)
    return model
  }
}

private actor RootSessionRunner: ProcessRunning {
  private(set) var callCount = 0

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    callCount += 1
    return .init(exitCode: 0, stdout: "", stderr: "")
  }
}
