import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("初回 worktree スキャンの再試行")
struct InitialScanRetryTests {
  @Test("git repository になれば初回スキャンが完了し失敗メッセージが消える")
  func recoversAfterGitInit() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try makeModel(directory: directory)
    defer { model.stop() }

    model.run()
    try await waitUntil { model.message != nil }
    #expect(model.message?.hasPrefix("worktree を検出できません:") == true)
    #expect(!model.didCompleteInitialScan)

    try await initializeRepository(at: directory)
    try await waitUntil { model.didCompleteInitialScan }

    #expect(model.message == nil)
    #expect(model.projectRoot != nil)
  }

  @Test("stop 後は repository にして run を再度呼んでも再試行しない")
  func stopPreventsRetry() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try makeModel(directory: directory)
    defer { model.stop() }

    model.run()
    try await waitUntil { model.message != nil }
    model.stop()
    try await initializeRepository(at: directory)
    model.run()
    try await Task.sleep(for: .milliseconds(300))

    #expect(!model.didCompleteInitialScan)
    #expect(model.projectRoot == nil)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeModel(directory: URL) throws -> AppModel {
    let identity = try #require(WorktreeIdentity(rawValue: directory.appending(path: ".git").path))
    return AppModel(
      project: RegisteredProject(commonDirectory: identity, directory: directory.path),
      dependencies: AppDependencies(
        launchProject: .none, tmuxExecutable: nil, tmuxError: nil,
        paneStates: nil, tmuxRunner: nil, paneSource: nil, signalSource: nil,
        sessionActivityProbe: nil, applicationSupportDirectory: nil, applicationSupportWarning: nil),
      notifier: nil, rescanInterval: .milliseconds(20))
  }

  private func initializeRepository(at directory: URL) async throws {
    let executable = try #require(
      GitRunner.defaultExecutableCandidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    let result = try await FoundationProcessRunner().run(
      executableURL: executable, arguments: ["-C", directory.path, "init"],
      environment: ["LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
      timeout: .seconds(5), outputLimit: 1024 * 1024)
    try #require(result.exitCode == 0)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }
}
