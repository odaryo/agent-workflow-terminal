import Darwin
import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// git 2.54.0 (Apple Git-157) 実測: 管理ディレクトリの `gitdir` が読めない・ディレクトリになっている
/// worktree と、`<common>/worktrees` が読めない (000 / 444) ときの linked worktree は、
/// `worktree list --porcelain -z` が **exit 0・stderr 空**のまま record を出さない (Issue #774)。
@Suite("§3.2 exit 0 で record が黙って欠けた worktree 一覧")
struct GitWorktreeSilentOmissionTests {
  @Test("管理ディレクトリの gitdir がディレクトリになった worktree が欠けたら一覧の失敗を返す")
  func gitdirDirectoryMakesListingIncomplete() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      let gitdir = common.appending(path: "worktrees/wt2/gitdir")
      try FileManager.default.removeItem(at: gitdir)
      try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: false)

      let result = try await detector(
        common, listing: try fixture("gitdir-directory")
      ).scan()

      #expect(result.listingFailure == Self.missingRecords)
      #expect(names(result.detected) == ["main", "wt1", "wt3"])
      #expect(result.failures.isEmpty)
    }
  }

  // root では chmod 000 が読み取りを妨げないため、この形は再現しない。
  @Test(
    "管理ディレクトリの gitdir を読めない worktree が欠けたら一覧の失敗を返す",
    .enabled(if: getuid() != 0))
  func unreadableGitdirMakesListingIncomplete() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try setPermissions(0o000, common.appending(path: "worktrees/wt2/gitdir"))

      let result = try await detector(
        common, listing: try fixture("gitdir-unreadable")
      ).scan()

      #expect(result.listingFailure == Self.missingRecords)
      #expect(names(result.detected) == ["main", "wt1", "wt3"])
      #expect(result.failures.isEmpty)
    }
  }

  /// 444 では readdir はできるが子を lstat できない (EACCES)。数えられない子も数に入れる。
  @Test(
    "worktrees ディレクトリを読めない・探索できないなら一覧の失敗を返す",
    .enabled(if: getuid() != 0),
    arguments: [
      (Int16(0o000), GitWorktreeOmission.administrativeDirectoriesUnreadable),
      (0o444, .missingRecords(administrativeDirectories: 3, linkedRecords: 0)),
    ])
  func unreadableWorktreesDirectoryMakesListingIncomplete(
    mode: Int16, omission: GitWorktreeOmission
  ) async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try setPermissions(mode, common.appending(path: "worktrees"))

      let result = try await detector(
        common, listing: try fixture("worktrees-unreadable")
      ).scan()

      #expect(result.listingFailure == .omittedRecords(omission))
      #expect(names(result.detected) == ["main"])
      #expect(result.failures.isEmpty)
    }
  }

  @Test("全 record が揃った exit 0 の一覧は、worktrees に管理ディレクトリでないファイルがあっても完全とする")
  func completeListingIgnoresNonDirectoryEntries() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try Data().write(to: common.appending(path: "worktrees/.DS_Store"))

      let result = try await detector(common, listing: try fixture()).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main", "wt1", "wt2", "wt3"])
    }
  }

  @Test("prunable の record も一覧に載った linked worktree として数える")
  func prunableRecordCountsAsListed() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      let result = try await detector(common, listing: try fixture("prunable")).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main", "wt1", "wt3"])
    }
  }

  /// gitdir が空のファイルは lstat で存在するので数える。git は一覧に出さないので、prune されるまで
  /// 毎回「不完全」になる (Issue #774 で受け入れた代償。git 2.54.0 の `worktree prune --dry-run` は
  /// `invalid gitdir file` として削除の対象に挙げる)。
  @Test("管理ディレクトリの gitdir が空のファイルで worktree が欠けたら一覧の失敗を返す")
  func emptyGitdirMakesListingIncomplete() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try Data().write(to: common.appending(path: "worktrees/wt2/gitdir"))

      let result = try await detector(common, listing: try fixture("gitdir-empty")).scan()

      #expect(result.listingFailure == Self.missingRecords)
      #expect(names(result.detected) == ["main", "wt1", "wt3"])
    }
  }

  /// git 自身も gitdir の無い管理ディレクトリを一覧に出さない (git 2.54.0 実測)。
  @Test("gitdir の無い管理ディレクトリは数えず、一覧を完全とする")
  func administrativeDirectoryWithoutGitdirIsNotCounted() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try FileManager.default.removeItem(at: common.appending(path: "worktrees/wt2/gitdir"))

      let result = try await detector(common, listing: try fixture("gitdir-missing")).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main", "wt1", "wt3"])
    }
  }

  @Test("中身の無い管理ディレクトリは数えず、一覧を完全とする")
  func emptyAdministrativeDirectoryIsNotCounted() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try FileManager.default.createDirectory(
        at: common.appending(path: "worktrees/junk"), withIntermediateDirectories: false)

      let result = try await detector(common, listing: try fixture("empty-admin-dir")).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main", "wt1", "wt2", "wt3"])
    }
  }

  /// git 2.54.0 実測: git は `worktrees/<id>` が symlink でも、たどった先の `gitdir` を読んで一覧に出す。
  @Test("symlink の管理ディレクトリは、たどった先がディレクトリなら数え、一覧を完全とする")
  func symlinkedAdministrativeDirectoryIsCounted() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try moveBehindSymlink(common, name: "wt2")

      let result = try await detector(common, listing: try fixture("admin-symlink")).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main", "wt1", "wt2", "wt3"])
    }
  }

  /// symlink を数えないと、symlink の wt2 が一覧に載り、gitdir を読めない wt3 が欠けても、
  /// 数が釣り合って欠けを見逃す (Issue #774 のレビュー、git 2.54.0 実測)。
  @Test(
    "symlink の管理ディレクトリがあっても、別の worktree が欠けたら一覧の失敗を返す",
    .enabled(if: getuid() != 0))
  func symlinkedAdministrativeDirectoryDoesNotHideOmission() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try moveBehindSymlink(common, name: "wt2")
      try setPermissions(0o000, common.appending(path: "worktrees/wt3/gitdir"))

      let result = try await detector(
        common, listing: try fixture("admin-symlink-gitdir-unreadable")
      ).scan()

      #expect(result.listingFailure == Self.missingRecords)
      #expect(names(result.detected) == ["main", "wt1", "wt2"])
    }
  }

  @Test("たどった先が無い symlink の管理ディレクトリは数えず、一覧を完全とする")
  func danglingSymlinkIsNotCounted() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt3"]) { common in
      try FileManager.default.createSymbolicLink(
        atPath: common.appending(path: "worktrees/wt2").path,
        withDestinationPath: common.deletingLastPathComponent().appending(path: "nowhere").path)

      let result = try await detector(
        common, listing: try fixture("admin-symlink-dangling")
      ).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main", "wt1", "wt3"])
    }
  }

  /// git 2.54.0 実測: たどった先の親が 000 の symlink では wt2 の record が出ず、出力は
  /// たどった先が無い形と同じ main / wt1 / wt3 だった (その形の fixture を使う)。
  @Test(
    "たどった先を権限で確かめられない symlink の管理ディレクトリは数える",
    .enabled(if: getuid() != 0))
  func symlinkBehindUnsearchableDirectoryIsCounted() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      let parent = common.deletingLastPathComponent().appending(path: "locked-parent")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      try moveBehindSymlink(common, name: "wt2", into: parent)
      try setPermissions(0o000, parent)

      let result = try await detector(
        common, listing: try fixture("admin-symlink-dangling")
      ).scan()

      #expect(result.listingFailure == Self.missingRecords)
    }
  }

  /// git 2.54.0 実測: `worktrees` が通常のファイルでも、git は exit 0 で main だけを出す。
  @Test("worktrees が通常のファイルなら main だけの一覧を完全とする")
  func worktreesFileIsComplete() async throws {
    try await withCommonDirectory(administrativeDirectories: nil) { common in
      try Data().write(to: common.appending(path: "worktrees"))

      let result = try await detector(common, listing: try fixture("worktrees-file")).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main"])
    }
  }

  /// git 2.54.0 実測: 改行1つの gitdir では、git は管理ディレクトリ自身をパスにした
  /// `prunable invalid gitdir file` の record を出すので、数えても釣り合う。
  @Test("gitdir が改行1つの管理ディレクトリは prunable の record と釣り合い、一覧を完全とする")
  func newlineGitdirIsBalancedByPrunableRecord() async throws {
    try await withCommonDirectory(administrativeDirectories: ["wt1", "wt2", "wt3"]) { common in
      try Data("\n".utf8).write(to: common.appending(path: "worktrees/wt2/gitdir"))

      let result = try await detector(common, listing: try fixture("gitdir-newline")).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main", "wt1", "wt3"])
    }
  }

  @Test("worktrees ディレクトリが無い main だけの一覧は完全とする")
  func missingWorktreesDirectoryIsComplete() async throws {
    try await withCommonDirectory(administrativeDirectories: nil) { common in
      let result = try await detector(
        common, listing: try fixture("worktrees-unreadable")
      ).scan()

      #expect(result.listingFailure == nil)
      #expect(names(result.detected) == ["main"])
    }
  }

  private static let missingRecords = GitWorktreeListingFailure.omittedRecords(
    .missingRecords(administrativeDirectories: 3, linkedRecords: 2))

  private func names(_ detected: [DetectedWorktree]) -> [String] {
    detected.map { URL(fileURLWithPath: $0.worktreePath).lastPathComponent }
  }

  private func fixture(_ shape: String? = nil) throws -> String {
    let name = ["git-2.54.0-worktree-list-porcelain-z", shape].compactMap(\.self)
      .joined(separator: "-")
    let url = try #require(
      Bundle.module.url(forResource: "\(name).txt", withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }

  private func detector(_ common: URL, listing: String) throws -> GitWorktreeDetector {
    let stub = SilentOmissionProcessStub(commonDirectory: common.path, listing: listing)
    return GitWorktreeDetector(
      projectRunner: try silentOmissionRunner(URL(fileURLWithPath: "/repo"), stub),
      makeRunner: { directory throws(GitRunnerError) in
        try silentOmissionRunner(directory, stub)
      },
      isWorktreeReachable: { _ in true },
      findAdministrativeDirectory: { _, _ in nil }
    )
  }
}

/// `administrativeDirectories` が `nil` なら `worktrees` ディレクトリ自体を作らない。各管理
/// ディレクトリには git と同じく `gitdir` を置く。権限を落としたものは後始末の前に戻す。
private func withCommonDirectory(
  administrativeDirectories: [String]?,
  _ body: (URL) async throws -> Void
) async throws {
  let root = URL(fileURLWithPath: "/private/tmp")
    .appending(path: "awt-silent-omission-\(UUID().uuidString)")
  let common = root.appending(path: ".git")
  let worktrees = common.appending(path: "worktrees")
  try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
  defer {
    restoreOwnerPermissions(under: root)
    try? FileManager.default.removeItem(at: root)
  }
  for name in administrativeDirectories ?? [] {
    let directory = worktrees.appending(path: name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data((root.appending(path: "\(name)/.git").path + "\n").utf8)
      .write(to: directory.appending(path: "gitdir"))
  }
  try await body(common)
}

/// `worktrees/<name>` を `into` (既定は common dir の親) の下へ移し、元の場所に symlink を置く。
private func moveBehindSymlink(_ common: URL, name: String, into parent: URL? = nil) throws {
  let original = common.appending(path: "worktrees/\(name)")
  let moved = (parent ?? common.deletingLastPathComponent()).appending(path: "\(name)-admin")
  try FileManager.default.moveItem(at: original, to: moved)
  try FileManager.default.createSymbolicLink(
    atPath: original.path, withDestinationPath: moved.path)
}

private func setPermissions(_ mode: Int16, _ url: URL) throws {
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
}

/// 権限を落としたディレクトリの下は列挙できないので、親から順に `chmod` で戻しながら辿る。
private func restoreOwnerPermissions(under url: URL) {
  _ = chmod(url.path, 0o755)
  guard let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
    return
  }
  for child in children {
    let path = url.appending(path: child)
    var info = stat()
    guard lstat(path.path, &info) == 0 else { continue }
    switch info.st_mode & S_IFMT {
    case S_IFDIR: restoreOwnerPermissions(under: path)
    // `chmod` は symlink をたどるので、たどった先のディレクトリを 644 にして消せなくしてしまう。
    case S_IFLNK: continue
    default: _ = chmod(path.path, 0o644)
    }
  }
}

private func silentOmissionRunner(
  _ directory: URL, _ processRunner: SilentOmissionProcessStub
) throws(GitRunnerError) -> GitRunner {
  try GitRunner(
    repositoryDirectory: directory, processRunner: processRunner,
    executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
    parentEnvironment: [:], isExecutableFile: { _ in true })
}

/// `worktree list` には exit 0 で `listing` を返し、`rev-parse` には実在する一時ディレクトリの
/// common dir を返す。entry の管理ディレクトリは作業ツリー名から `<common>/worktrees/<name>` とする。
private actor SilentOmissionProcessStub: ProcessRunning {
  private let commonDirectory: String
  private let listing: String

  init(commonDirectory: String, listing: String) {
    self.commonDirectory = commonDirectory
    self.listing = listing
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    if arguments.contains("worktree") {
      return .init(exitCode: 0, stdout: listing, stderr: "")
    }
    guard arguments.contains("--git-dir") else {
      return .init(exitCode: 0, stdout: "\(commonDirectory)\n", stderr: "")
    }
    guard let index = arguments.firstIndex(of: "-C"), index + 1 < arguments.count else {
      throw .cancelled
    }
    let name = URL(fileURLWithPath: arguments[index + 1]).lastPathComponent
    let gitDirectory = name == "main" ? commonDirectory : "\(commonDirectory)/worktrees/\(name)"
    let linkedAttributes = arguments.contains("--show-prefix") ? "false\n\n" : ""
    return .init(
      exitCode: 0, stdout: "\(gitDirectory)\n\(commonDirectory)\n" + linkedAttributes, stderr: "")
  }
}
