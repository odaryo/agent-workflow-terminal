import Adapters
import Foundation
import TerminalCore
import Testing

@Suite("登録済み Project の一覧の保存 (Issue #372)")
struct ProjectRegistryStoreTests {

  // MARK: - Helpers

  private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("awt-project-registry-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
  }

  private func registry() throws -> PersistedProjectRegistry {
    let alpha = RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/alpha/.git")),
      directory: "/alpha"
    )
    let beta = RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/beta.git")),
      directory: "/beta.git"
    )
    var registry = ProjectRegistry()
    registry.register(alpha)
    registry.register(beta)
    registry.select(alpha.commonDirectory)
    return PersistedProjectRegistry(registry)
  }

  private func capturedError(_ body: () async throws -> Void) async -> (any Error)? {
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
      let store = ProjectRegistryStore(fileURL: directory.appendingPathComponent("a.json"))
      let saved = try registry()

      try await store.save(saved)
      let loaded = try await store.load()

      #expect(loaded == saved)
    }
  }

  @Test("中間ディレクトリが無ければ作り、一時ファイルを残さない")
  func saveCreatesIntermediateDirectoriesWithoutLeftovers() async throws {
    try await withTemporaryDirectory { directory in
      let parent = directory.appendingPathComponent("AgentWorkflowTerminal", isDirectory: true)
      let store = ProjectRegistryStore(fileURL: parent.appendingPathComponent("a.json"))
      let saved = try registry()

      try await store.save(saved)
      try await store.save(saved)

      let loaded = try await store.load()
      let contents = try FileManager.default.contentsOfDirectory(atPath: parent.path)

      #expect(loaded == saved)
      #expect(contents == ["a.json"])
    }
  }

  @Test("保存した JSON のパスをエスケープしない")
  func savedJSONDoesNotEscapeSlashes() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      try await ProjectRegistryStore(fileURL: fileURL).save(try registry())

      let text = try String(contentsOf: fileURL, encoding: .utf8)

      #expect(!text.contains(#"\/"#))
      #expect(text.contains(#""commonDirectory" : "/alpha/.git""#))
    }
  }

  // MARK: - 読み取り

  @Test("ファイルが無ければ nil を返す")
  func loadReturnsNilWhenAbsent() async throws {
    try await withTemporaryDirectory { directory in
      let store = ProjectRegistryStore(
        fileURL: directory.appendingPathComponent("missing", isDirectory: true)
          .appendingPathComponent("a.json"))

      let loaded = try await store.load()

      #expect(loaded == nil)
    }
  }

  @Test("リンク先の無い symlink は「保存が無い」と区別して throw する")
  func loadThrowsOnBrokenSymbolicLink() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      try FileManager.default.createSymbolicLink(
        atPath: fileURL.path,
        withDestinationPath: directory.appendingPathComponent("nowhere.json").path
      )

      let error = await capturedError {
        _ = try await ProjectRegistryStore(fileURL: fileURL).load()
      }

      guard case .readFailed = try #require(error as? ProjectRegistryStoreError) else {
        Issue.record("readFailed を期待したが \(String(describing: error))")
        return
      }
    }
  }

  @Test("壊れた JSON は nil へ丸めず throw する")
  func loadThrowsOnMalformedJSON() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      try Data("{ not json".utf8).write(to: fileURL)

      let error = await capturedError {
        _ = try await ProjectRegistryStore(fileURL: fileURL).load()
      }

      guard case .malformed = try #require(error as? ProjectRegistryStoreError) else {
        Issue.record("malformed を期待したが \(String(describing: error))")
        return
      }
    }
  }

  @Test("未知の schemaVersion は nil へ丸めず throw する")
  func loadThrowsOnUnknownSchemaVersion() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = directory.appendingPathComponent("a.json")
      let future = PersistedProjectRegistry.currentSchemaVersion + 1
      try Data(#"{"schemaVersion":\#(future),"projects":[]}"#.utf8).write(to: fileURL)

      let error = await capturedError {
        _ = try await ProjectRegistryStore(fileURL: fileURL).load()
      }

      guard
        case .unsupportedSchemaVersion(_, let found, let supported) = try #require(
          error as? ProjectRegistryStoreError)
      else {
        Issue.record("unsupportedSchemaVersion を期待したが \(String(describing: error))")
        return
      }
      #expect(found == future)
      #expect(supported == PersistedProjectRegistry.currentSchemaVersion)
    }
  }

  // MARK: - 既定パス

  @Test("既定パスは Application Support/AgentWorkflowTerminal 直下に置く")
  func defaultFileURLLivesInApplicationDirectory() {
    let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support")

    let url = ProjectRegistryStore.defaultFileURL(applicationSupportDirectory: base)

    #expect(url.path == base.path + "/AgentWorkflowTerminal/project-registry.json")
  }
}
