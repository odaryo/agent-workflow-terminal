import Adapters
import Darwin
import Foundation
import TerminalCore
import Testing

@Suite("worktree Active/Inactiveの保存 (設計書 §22.1 / Issue #136)")
struct WorktreeInventoryStoreTests {

  // MARK: - Helpers

  private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("awt-inventory-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
  }

  private func inventory(active: Bool) throws -> PersistedWorktreeInventory {
    let root = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git")),
      worktreePath: "/repo",
      branch: "main",
      isProjectRoot: true
    )
    let alpha = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/alpha")),
      worktreePath: "/wt/alpha",
      branch: "feat/alpha",
      isProjectRoot: false
    )
    return PersistedWorktreeInventory(
      WorktreeInventory(
        projectRoot: root,
        taskWorktrees: [TaskWorktree(detected: alpha, activation: active ? .active : .inactive)]
      )
    )
  }

  private func capturedError(
    _ body: () async throws -> Void
  ) async -> (any Error)? {
    do {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  // MARK: - ラウンドトリップ

  @Test("保存した内容をそのまま読み戻す")
  func saveThenLoad() async throws {
    try await withTemporaryDirectory { directory in
      let store = WorktreeInventoryStore(fileURL: directory.appendingPathComponent("a.json"))
      let saved = try inventory(active: true)

      try await store.save(saved)
      let loaded = try await store.load()

      #expect(loaded == saved)
    }
  }

  @Test("中間ディレクトリが無ければ作る")
  func saveCreatesIntermediateDirectories() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL =
        directory
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent("deadbeef", isDirectory: true)
        .appendingPathComponent("worktrees.json")
      let store = WorktreeInventoryStore(fileURL: fileURL)
      let saved = try inventory(active: true)

      try await store.save(saved)
      let loaded = try await store.load()

      #expect(loaded == saved)
    }
  }

  @Test("上書き保存は前の内容を残さない")
  func saveReplacesPreviousContent() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      let store = WorktreeInventoryStore(fileURL: fileURL)
      try await store.save(try inventory(active: true))

      let replacement = PersistedWorktreeInventory(
        WorktreeInventory(projectRoot: nil, taskWorktrees: [])
      )
      try await store.save(replacement)
      let loaded = try await store.load()

      #expect(loaded == replacement)
      let text = try String(contentsOf: fileURL, encoding: .utf8)
      #expect(!text.contains("alpha"))
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(leftovers == ["a.json"])
    }
  }

  // MARK: - 保存の失敗

  @Test("保存に失敗しても保存先の前の内容をそのまま残す")
  func failedSaveLeavesPreviousContentIntact() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      let store = WorktreeInventoryStore(fileURL: fileURL)
      let original = try inventory(active: true)
      try await store.save(original)
      let originalBytes = try Data(contentsOf: fileURL)

      // ディレクトリを読み取り専用にすると一時ファイルを作れない。macOS 26.5 実測: この状態でも
      // 既存ファイルへの直接書き込みは成功するため、原子的置換を捨てた実装はここで気づかず
      // 保存先を上書きしてしまう。root ではパーミッションが効かないので前提を明示する。
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      }
      try #require(!FileManager.default.isWritableFile(atPath: directory.path))

      let error = await capturedError {
        try await store.save(
          PersistedWorktreeInventory(WorktreeInventory(projectRoot: nil, taskWorktrees: []))
        )
      }

      guard case .writeFailed = try #require(error as? WorktreeInventoryStoreError) else {
        Issue.record("writeFailed を期待したが \(String(describing: error))")
        return
      }
      let bytesAfterFailure = try Data(contentsOf: fileURL)
      #expect(bytesAfterFailure == originalBytes)
    }
  }

  @Test("置換に失敗しても一時ファイルを残さない")
  func failedReplacementLeavesNoTemporaryFile() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      let store = WorktreeInventoryStore(fileURL: fileURL)
      let original = try inventory(active: true)
      try await store.save(original)

      // 一時ファイルの作成までは成功させ、置換だけを失敗させる。macOS 26.5 実測: 保存先に
      // `UF_IMMUTABLE` を立てると `replaceItemAt` が NSCocoaErrorDomain 513 で失敗し、
      // 一時ファイルは作られたまま残る。
      try #require(chflags(fileURL.path, UInt32(UF_IMMUTABLE)) == 0)
      defer { _ = chflags(fileURL.path, 0) }

      let error = await capturedError { try await store.save(try inventory(active: false)) }

      guard case .writeFailed = try #require(error as? WorktreeInventoryStoreError) else {
        Issue.record("writeFailed を期待したが \(String(describing: error))")
        return
      }
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(leftovers == ["a.json"])
      let loaded = try await store.load()
      #expect(loaded == original)
    }
  }

  @Test("保存したJSONのパスをエスケープしない")
  func encodedPathsAreNotEscaped() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      let store = WorktreeInventoryStore(fileURL: fileURL)

      try await store.save(try inventory(active: true))

      let text = try String(contentsOf: fileURL, encoding: .utf8)
      #expect(!text.contains(#"\/"#))
      #expect(text.contains("/repo/.git/worktrees/alpha"))
    }
  }

  // MARK: - 読み取りの失敗の区別

  @Test("ファイルが無ければnilを返す")
  func loadReturnsNilWhenFileIsAbsent() async throws {
    try await withTemporaryDirectory { directory in
      let store = WorktreeInventoryStore(fileURL: directory.appendingPathComponent("absent.json"))
      let loaded = try await store.load()

      #expect(loaded == nil)
    }
  }

  @Test("親ディレクトリごと無くてもnilを返す")
  func loadReturnsNilWhenParentDirectoryIsAbsent() async throws {
    try await withTemporaryDirectory { directory in
      let store = WorktreeInventoryStore(
        fileURL:
          directory
          .appendingPathComponent("never-created", isDirectory: true)
          .appendingPathComponent("absent.json")
      )
      let loaded = try await store.load()

      #expect(loaded == nil)
    }
  }

  @Test("リンク先の無いsymlinkは「保存が無い」と区別してthrowする")
  func loadThrowsOnBrokenSymbolicLink() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      try FileManager.default.createSymbolicLink(
        atPath: fileURL.path,
        withDestinationPath: directory.appendingPathComponent("nowhere.json").path
      )
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let error = await capturedError { _ = try await store.load() }

      guard case .readFailed = try #require(error as? WorktreeInventoryStoreError) else {
        Issue.record("readFailed を期待したが \(String(describing: error))")
        return
      }
    }
  }

  @Test("壊れたJSONはnilへ丸めずthrowする")
  func loadThrowsOnMalformedJSON() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      try Data("{ not json".utf8).write(to: fileURL)
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let error = await capturedError { _ = try await store.load() }

      guard case .malformed = try #require(error as? WorktreeInventoryStoreError) else {
        Issue.record("malformed を期待したが \(String(describing: error))")
        return
      }
    }
  }

  @Test("未知のschemaVersionはnilへ丸めずthrowする")
  func loadThrowsOnUnknownSchemaVersion() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      let future = PersistedWorktreeInventory.currentSchemaVersion + 1
      try Data(#"{"schemaVersion":\#(future),"taskWorktrees":[]}"#.utf8).write(to: fileURL)
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let error = await capturedError { _ = try await store.load() }

      guard
        case .unsupportedSchemaVersion(_, let found, let supported) = try #require(
          error as? WorktreeInventoryStoreError)
      else {
        Issue.record("unsupportedSchemaVersion を期待したが \(String(describing: error))")
        return
      }
      #expect(found == future)
      #expect(supported == PersistedWorktreeInventory.currentSchemaVersion)
    }
  }

  @Test("読み取れないファイルは「保存が無い」と区別してthrowする")
  func loadThrowsOnUnreadableFile() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      try Data("{}".utf8).write(to: fileURL)
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
      }
      // root で走らせるとパーミッションを無視して読めてしまい、この検証は成立しない。
      try #require(!FileManager.default.isReadableFile(atPath: fileURL.path))
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let error = await capturedError { _ = try await store.load() }

      guard case .readFailed = try #require(error as? WorktreeInventoryStoreError) else {
        Issue.record("readFailed を期待したが \(String(describing: error))")
        return
      }
    }
  }

  // MARK: - 既定パス

  @Test("既定パスは同じProject Rootから決定的に決まり、Project Rootが違えば分かれる")
  func defaultFileURLIsDeterministicPerProjectRoot() throws {
    let base = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)
    let one = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let other = try #require(WorktreeIdentity(rawValue: "/other/.git"))

    let first = WorktreeInventoryStore.defaultFileURL(
      applicationSupportDirectory: base, projectRootIdentity: one)
    let again = WorktreeInventoryStore.defaultFileURL(
      applicationSupportDirectory: base, projectRootIdentity: one)
    let different = WorktreeInventoryStore.defaultFileURL(
      applicationSupportDirectory: base, projectRootIdentity: other)

    #expect(first == again)
    #expect(first != different)
    #expect(first.path.hasPrefix(base.path + "/AgentWorkflowTerminal/projects/"))
  }

  @Test("既定パスのディレクトリ名は安定IDのパス区切りを含まない")
  func defaultFileURLDirectoryNameIsOpaque() throws {
    let base = URL(fileURLWithPath: "/base", isDirectory: true)
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/with space/.git"))

    let url = WorktreeInventoryStore.defaultFileURL(
      applicationSupportDirectory: base, projectRootIdentity: identity)
    let projectDirectory = url.deletingLastPathComponent().lastPathComponent

    #expect(projectDirectory.count == 64)
    #expect(projectDirectory.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }
}
