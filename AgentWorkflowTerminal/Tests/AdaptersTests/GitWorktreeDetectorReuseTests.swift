import Foundation
import TerminalCore
import Testing
import os

@testable import Adapters

@Suite("到達可能な linked worktree の観測再利用 (Issue #401)")
struct GitWorktreeDetectorReuseTests {
  @Test("再利用時は runner も git も起動せず、今回の branch と前回の ID を返す", arguments: [false, true])
  func reusesIdentityWithCurrentBranch(detached: Bool) async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub(linkedFields: detached ? "detached" : "branch refs/heads/current")
    let calls = SynchronousCalls()
    let detector = try fixture.detector(stub, calls: calls)

    let result = try await detector.scan(reusableObservations: [fixture.observation()])

    #expect(result.detected.last == fixture.observation(branch: detached ? nil : "current"))
    #expect(result.failures.isEmpty)
    #expect(await stub.invocations.allSatisfy { !$0.contains(fixture.linkedPath) })
    #expect(!calls.paths.contains("runner:\(fixture.linkedPath)"))
    #expect(calls.paths.contains("finder:\(fixture.linkedPath):\(fixture.commonPath)"))
  }

  @Test("同じパスの到達不能・Project Root 観測を飛ばして最初の再利用可能な観測を使う")
  func skipsIneligibleObservations() async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub()

    let result = try await fixture.detector(stub).scan(reusableObservations: [
      fixture.observation(observation: .unreachable),
      fixture.observation(isProjectRoot: true), fixture.observation(),
    ])

    #expect(await stub.invocations.allSatisfy { !$0.contains(fixture.linkedPath) })
    #expect(result.detected.last == fixture.observation(branch: "current"))
  }

  @Test("再利用した entry も同じ安定 ID の組の解決を通る")
  func reusedEntryStillResolvesSharedIdentities() async throws {
    let fixture = try ReuseFixture()
    let duplicatePath = "\(fixture.root)/duplicate"
    let stub = ProcessRunnerStub { arguments in
      if arguments.contains("worktree") {
        return ProcessRunResult(
          exitCode: 0,
          stdout: "worktree \(fixture.mainPath)\0branch refs/heads/main\0\0"
            + "worktree \(duplicatePath)\0detached\0\0"
            + "worktree \(fixture.linkedPath)\0branch refs/heads/current\0\0",
          stderr: "")
      }
      return ProcessRunResult(
        exitCode: 0,
        stdout: arguments.contains("--git-dir")
          ? (arguments.contains(fixture.mainPath)
            ? "\(fixture.commonPath)\n\(fixture.commonPath)\n"
            : "\(fixture.identity.rawValue)\n\(fixture.commonPath)\nfalse\n\n")
          : "\(fixture.commonPath)\n", stderr: "")
    }
    let result = try await fixture.detector(stub).scan(
      reusableObservations: [fixture.observation()])

    #expect(result.detected.map(\.worktreePath) == [fixture.mainPath, fixture.linkedPath])
    #expect(
      result.failures == [
        GitWorktreeEntryFailure(
          worktreePath: duplicatePath,
          reason: .sharedIdentity(gitDirectory: fixture.identity.rawValue))
      ])
    #expect(await stub.invocations.allSatisfy { !$0.contains(fixture.linkedPath) })
  }

  @Test("理由の有無によらず locked は rev-parse する", arguments: ["locked", "locked removable volume"])
  func lockedEntryIsNotReused(field: String) async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub(linkedFields: "branch refs/heads/current\0\(field)")
    let result = try await fixture.detector(stub).scan(
      reusableObservations: [fixture.observation()])

    #expect(await stub.invocations.contains(fixture.linkedArguments))
    #expect(result.detected.last == fixture.observation(branch: "current"))
  }

  @Test("prunable は再利用せず既存の到達不能判定または除外を保つ", arguments: [false, true])
  func prunableEntryKeepsExistingTreatment(reachable: Bool) async throws {
    let fixture = try ReuseFixture()
    let directory = URL(fileURLWithPath: fixture.linkedPath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let stub = fixture.stub(linkedFields: "branch refs/heads/current\0prunable stale gitdir")
    let detector = try fixture.detector(stub, reachable: reachable)

    let result = try await detector.scan(reusableObservations: [fixture.observation()])

    #expect(await stub.invocations.allSatisfy { !$0.contains(fixture.linkedPath) })
    #expect(result.prunable == [fixture.identity])
    #expect(result.failures.isEmpty)
    if reachable {
      #expect(result.detected.map(\.worktreePath) == [fixture.mainPath])
    } else {
      #expect(
        result.detected.last
          == fixture.observation(branch: "current", observation: .unreachable))
    }
  }

  @Test(
    "到達可能と確認できていない観測は再利用しない",
    arguments: [WorktreeObservation.unreachable, .observationFailed]
  )
  func unsuccessfulObservationIsNotReused(observation: WorktreeObservation) async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub()

    let result = try await fixture.detector(stub).scan(
      reusableObservations: [fixture.observation(observation: observation)])

    #expect(await stub.invocations.contains(fixture.linkedArguments))
    #expect(result.detected.last == fixture.observation(branch: "current"))
  }

  @Test("管理ディレクトリが無いか ID が変わった場合は git が返す ID を使う", arguments: [false, true])
  func missingOrChangedAdministrativeIdentityIsNotReused(missing: Bool) async throws {
    let fixture = try ReuseFixture()
    let newIdentity = try #require(
      WorktreeIdentity(rawValue: "\(fixture.commonPath)/worktrees/new"))
    let stub = fixture.stub(linkedIdentity: newIdentity)
    let detector = try fixture.detector(stub, finder: { _, _ in missing ? nil : newIdentity })

    let result = try await detector.scan(reusableObservations: [fixture.observation()])

    #expect(await stub.invocations.contains(fixture.linkedArguments))
    #expect(result.detected.last?.identity == newIdentity)
    #expect(result.detected.last?.observation == .reachable)
  }

  @Test("最初の entry は観測の Project Root フラグによらず rev-parse する", arguments: [false, true])
  func mainWorktreeIsNeverReused(isProjectRoot: Bool) async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub()
    let previous = DetectedWorktree(
      identity: fixture.commonIdentity, worktreePath: fixture.mainPath, branch: "old",
      isProjectRoot: isProjectRoot)

    let result = try await fixture.detector(stub).scan(reusableObservations: [previous])

    #expect(await stub.invocations.contains(fixture.mainArguments))
    #expect(result.detected.first?.isProjectRoot == true)
    #expect(result.detected.first?.branch == "main")
  }

  @Test("linked entry と同じパスでも Project Root の観測は使わない")
  func projectRootObservationIsNotReused() async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub()

    let result = try await fixture.detector(stub).scan(
      reusableObservations: [fixture.observation(isProjectRoot: true)])

    #expect(await stub.invocations.contains(fixture.linkedArguments))
    #expect(result.detected.last == fixture.observation(branch: "current"))
  }

  @Test("再利用する entry の作業ツリー側 FS 述語は呼ばない")
  func reuseDoesNotProbeWorkingTreeReachability() async throws {
    let fixture = try ReuseFixture()
    // 現状の describe なら exit 128 の後に述語へ進むため、呼び出し禁止を独立に検証できる。
    let stub = fixture.stub(linkedExitCode: 128)
    let calls = SynchronousCalls()

    let result = try await fixture.detector(stub, calls: calls, reachable: false).scan(
      reusableObservations: [fixture.observation()])

    #expect(!calls.paths.contains("reachable:\(fixture.linkedPath)"))
    #expect(result.detected.last == fixture.observation(branch: "current"))
    #expect(result.failures.isEmpty)
  }

  @Test("引数省略時は従来の git 引数列で全 entry を問い合わせる")
  func omittedObservationsKeepExistingArguments() async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub()

    _ = try await fixture.detector(stub).scan()

    #expect(
      await stub.invocations == [
        fixture.prefix(fixture.mainPath) + ["worktree", "list", "--porcelain", "-z"],
        fixture.prefix(fixture.mainPath)
          + ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        fixture.mainArguments, fixture.linkedArguments,
      ])
  }

  @Test("パスが違う観測は再利用しない")
  func differentPathIsNotReused() async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub()
    let previous = DetectedWorktree(
      identity: fixture.identity, worktreePath: "\(fixture.linkedPath)-old", branch: "old",
      isProjectRoot: false)

    _ = try await fixture.detector(stub).scan(reusableObservations: [previous])

    #expect(await stub.invocations.contains(fixture.linkedArguments))
  }

  @Test("同じパスの再利用可能な観測は最初のものを照合し、不一致なら git に戻る")
  func firstMatchingObservationDeterminesReuse() async throws {
    let fixture = try ReuseFixture()
    let stub = fixture.stub()
    let oldIdentity = try #require(
      WorktreeIdentity(rawValue: "\(fixture.commonPath)/worktrees/old"))
    let first = DetectedWorktree(
      identity: oldIdentity, worktreePath: fixture.linkedPath, branch: "old", isProjectRoot: false)

    let result = try await fixture.detector(stub).scan(
      reusableObservations: [first, fixture.observation()])

    #expect(await stub.invocations.contains(fixture.linkedArguments))
    #expect(result.detected.last?.identity == fixture.identity)
  }
}

private struct ReuseFixture: Sendable {
  let root: String
  var mainPath: String { "\(root)/main" }
  var linkedPath: String { "\(root)/linked" }
  var commonPath: String { "\(mainPath)/.git" }
  let commonIdentity: WorktreeIdentity
  let identity: WorktreeIdentity

  init() throws {
    let directory = "/private/tmp/awt-reuse-\(UUID().uuidString)"
    root = directory
    let common = "\(directory)/main/.git"
    commonIdentity = try #require(WorktreeIdentity(rawValue: common))
    identity = try #require(WorktreeIdentity(rawValue: "\(common)/worktrees/linked"))
  }
  var mainArguments: [String] {
    prefix(mainPath) + ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"]
  }
  var linkedArguments: [String] {
    prefix(linkedPath) + [
      "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
      "--is-bare-repository", "--show-prefix",
    ]
  }

  func prefix(_ path: String) -> [String] {
    ["--no-optional-locks", "-C", path, "--no-pager"]
  }

  func observation(
    branch: String? = "previous", isProjectRoot: Bool = false,
    observation: WorktreeObservation = .reachable
  ) -> DetectedWorktree {
    DetectedWorktree(
      identity: identity, worktreePath: linkedPath, branch: branch,
      isProjectRoot: isProjectRoot, observation: observation)
  }

  func stub(
    linkedFields: String = "branch refs/heads/current",
    linkedIdentity: WorktreeIdentity? = nil, linkedExitCode: Int32 = 0
  ) -> ProcessRunnerStub {
    let administrativePath = linkedIdentity?.rawValue ?? identity.rawValue
    return ProcessRunnerStub { arguments in
      if arguments.contains("worktree") {
        return ProcessRunResult(
          exitCode: 0,
          stdout: "worktree \(mainPath)\0branch refs/heads/main\0\0"
            + "worktree \(linkedPath)\0\(linkedFields)\0\0", stderr: "")
      }
      let stdout: String
      if !arguments.contains("--git-dir") {
        stdout = "\(commonPath)\n"
      } else if arguments.contains(linkedPath) {
        stdout = "\(administrativePath)\n\(commonPath)\nfalse\n\n"
      } else {
        stdout = "\(commonPath)\n\(commonPath)\n"
      }
      return ProcessRunResult(
        exitCode: arguments.contains(linkedPath) ? linkedExitCode : 0,
        stdout: stdout, stderr: "")
    }
  }

  func detector(
    _ stub: ProcessRunnerStub, calls: SynchronousCalls = SynchronousCalls(), reachable: Bool = true,
    finder: (@Sendable (String, WorktreeIdentity) -> WorktreeIdentity?)? = nil
  ) throws -> GitWorktreeDetector {
    let expectedIdentity = identity
    let expectedCommonIdentity = commonIdentity
    return GitWorktreeDetector(
      projectRunner: try runner(URL(fileURLWithPath: mainPath), stub),
      makeRunner: { directory throws(GitRunnerError) in
        calls.record("runner:\(directory.path)")
        return try runner(directory, stub)
      },
      isWorktreeReachable: { path in
        calls.record("reachable:\(path)")
        return reachable
      },
      findAdministrativeDirectory: { path, common in
        calls.record("finder:\(path):\(common.rawValue)")
        if let finder { return finder(path, common) }
        return path == linkedPath && common == expectedCommonIdentity ? expectedIdentity : nil
      })
  }

  private func runner(
    _ directory: URL, _ stub: ProcessRunnerStub
  ) throws(GitRunnerError) -> GitRunner {
    try GitRunner(
      repositoryDirectory: directory, processRunner: stub,
      executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: [:], isExecutableFile: { _ in true })
  }
}

// 同期の注入コールバック内で記録を確定する必要があるため、actor への非同期 hop は使えない。
private final class SynchronousCalls: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: [String]())
  var paths: [String] { storage.withLock { $0 } }
  func record(_ path: String) { storage.withLock { $0.append(path) } }
}

private actor ProcessRunnerStub: ProcessRunning {
  private let handler: @Sendable ([String]) -> ProcessRunResult
  private(set) var invocations: [[String]] = []

  init(handler: @escaping @Sendable ([String]) -> ProcessRunResult) {
    self.handler = handler
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    return handler(arguments)
  }
}
