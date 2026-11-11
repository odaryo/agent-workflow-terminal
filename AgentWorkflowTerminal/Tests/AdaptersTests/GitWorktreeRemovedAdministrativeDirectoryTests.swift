import Darwin
import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("§3.2 管理ディレクトリの消失の証拠 (#870)")
struct GitWorktreeRemovedDirectoryTests {
  @Test("存在しない ID だけを入力順に返し、重複は最初の1件にする (A1)")
  func missingIdentitiesAreOrderedAndUnique() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1"]) { common in
      let existing = try identity(common.appending(path: "worktrees/wt1").path)
      let wt3 = try identity(common.appending(path: "worktrees/wt3").path)
      let wt2 = try identity(common.appending(path: "worktrees/wt2").path)

      let result = GitWorktreeDetector.removedAdministrativeDirectories(
        [existing, wt3, wt2, wt3, existing, wt2], commonDirectory: try identity(common.path))

      #expect(result == [wt3, wt2])
    }
  }

  @Test("common dir が存在しなければ消失の証拠にしない (A1)")
  func missingCommonDirectoryDoesNotRemoveIdentities() async throws {
    try await withCommonDirectory(administrativeDirectories: nil) { common in
      let known = try identity(common.appending(path: "worktrees/wt1").path)
      try FileManager.default.removeItem(at: common)

      #expect(
        GitWorktreeDetector.removedAdministrativeDirectories(
          [known], commonDirectory: try identity(common.path)
        ).isEmpty)
    }
  }

  // root では chmod 000 が読み取りを妨げないため、この形は再現しない。
  @Test("worktrees の探索権限が無く EACCES なら消失にしない (A1)", .enabled(if: getuid() != 0))
  func unsearchableParentDoesNotRemoveIdentity() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1"]) { common in
      let existing = try identity(common.appending(path: "worktrees/wt1").path)
      let missing = try identity(common.appending(path: "worktrees/missing").path)
      try setPermissions(0o000, common.appending(path: "worktrees"))
      var info = stat()
      let status = lstat(missing.rawValue, &info)
      let error = errno
      #expect(status == -1)
      #expect(error == EACCES)

      #expect(
        GitWorktreeDetector.removedAdministrativeDirectories(
          [existing, missing], commonDirectory: try identity(common.path)
        ).isEmpty)
    }
  }

  @Test("たどった先の無い symlink は lstat で存在するので消失にしない (A1)")
  func danglingSymlinkIsNotRemoved() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1"]) { common in
      let link = common.appending(path: "worktrees/dangling")
      try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: common.appending(path: "nowhere").path)

      #expect(
        GitWorktreeDetector.removedAdministrativeDirectories(
          [try identity(link.path)], commonDirectory: try identity(common.path)
        ).isEmpty)
    }
  }

  @Test("exit 0 で wt2 が黙って欠けた回に、管理ディレクトリが無い wt3 を返す (A2)")
  func silentOmissionReportsRemovedIdentity() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2"]) { common in
      let gitdir = common.appending(path: "worktrees/wt2/gitdir")
      try FileManager.default.removeItem(at: gitdir)
      try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: false)
      let known = try identities(common, names: ["wt1", "wt2", "wt3"])

      let result = try await detector(common, names: ["main", "wt1"]).scan(knownIdentities: known)

      #expect(
        result.listingFailure
          == .omittedRecords(.missingRecords(administrativeDirectories: 2, linkedRecords: 1)))
      #expect(result.detected.map(\.branch) == ["main", "wt1"])
      #expect(result.failures.isEmpty)
      #expect(result.removed == [known[2]])
    }
  }

  @Test("完全な一覧では存在しない既知の ID があっても removed は空 (A2)")
  func completeListingDoesNotReportRemovedIdentity() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1"]) { common in
      let result = try await detector(common, names: ["main", "wt1"]).scan(
        knownIdentities: try identities(common, names: ["wt1", "wt3"]))

      #expect(result.listingFailure == nil)
      #expect(result.removed.isEmpty)
      #expect(result.detected.map(\.branch) == ["main", "wt1"])
    }
  }

  @Test("exit 128 の部分一覧でも管理ディレクトリが無い ID を返す (A2)")
  func partialCommandFailureReportsRemovedIdentity() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2"]) { common in
      let known = try identities(common, names: ["wt1", "wt2", "wt3"])
      let result = try await detector(common, names: ["main", "wt1"], exitCode: 128).scan(
        knownIdentities: known)

      guard let failure = result.listingFailure,
        case .command(.commandFailed(let code, _, _)) = failure
      else {
        Issue.record("exit 128 の一覧失敗が必要")
        return
      }
      #expect(code == 128)
      #expect(result.detected.map(\.branch) == ["main", "wt1"])
      #expect(result.failures.isEmpty)
      #expect(result.removed == [known[2]])
    }
  }

  private func identity(_ path: String) throws -> WorktreeIdentity {
    try #require(WorktreeIdentity(rawValue: path))
  }

  private func identities(_ common: URL, names: [String]) throws -> [WorktreeIdentity] {
    try names.map { try identity(common.appending(path: "worktrees/\($0)").path) }
  }

  private func detector(
    _ common: URL, names: [String], exitCode: Int32 = 0
  ) throws -> GitWorktreeDetector {
    let listing = names.map { "worktree /wt/\($0)\0branch refs/heads/\($0)\0\0" }.joined()
    let stub = SilentOmissionProcessStub(
      commonDirectory: common.path, listing: listing, exitCode: exitCode)
    return GitWorktreeDetector(
      projectRunner: try silentOmissionRunner(common.deletingLastPathComponent(), stub),
      makeRunner: { directory throws(GitRunnerError) in
        try silentOmissionRunner(directory, stub)
      },
      isWorktreeReachable: { _ in true },
      findAdministrativeDirectory: { _, _ in nil })
  }
}
