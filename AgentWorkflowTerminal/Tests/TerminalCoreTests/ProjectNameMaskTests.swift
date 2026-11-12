import Foundation
import TerminalCore
import Testing

@Suite("Project 名のマスク (#1001)")
struct ProjectNameMaskTests {
  @Test(
    "先頭の書記素クラスタと固定3個の U+2022 を返す",
    arguments: [
      ("agent-workflow-terminal", "a•••"),
      ("a", "a•••"),
      ("日本語プロジェクト", "日•••"),
      ("👨‍👩‍👧repo", "👨‍👩‍👧•••"),
      ("", "•••"),
    ])
  func masksName(name: String, expected: String) {
    #expect(ProjectNameMask.masked(name) == expected)
  }

  private func project(masksName: Bool = false) throws -> RegisteredProject {
    RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/alpha/.git")),
      directory: "/alpha", agentCommand: "codex", masksName: masksName
    )
  }

  @Test("既存の初期化では名前を伏せない")
  func defaultsToUnmasked() throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/alpha/.git"))
    let defaultProject = RegisteredProject(commonDirectory: identity, directory: "/alpha")
    let customCommand = RegisteredProject(
      commonDirectory: identity, directory: "/alpha", agentCommand: "codex")

    #expect(defaultProject.masksName == false)
    #expect(customCommand.masksName == false)
  }

  @Test("初期化で指定したマスク設定を保持する", arguments: [false, true])
  func initializerPreservesMasksName(masksName: Bool) throws {
    #expect(try project(masksName: masksName).masksName == masksName)
  }

  @Test(
    "対象だけのマスク設定を変更し、一覧の順序と選択を保つ",
    arguments: [false, true], [false, true])
  func setsMasksName(masksName: Bool, previousMasksName: Bool) throws {
    var alpha = try project(masksName: previousMasksName)
    let beta = RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/beta/.git")),
      directory: "/beta", masksName: true
    )
    var registry = ProjectRegistry()
    registry.register(alpha)
    registry.register(beta)

    let updated = registry.setMasksName(masksName, of: alpha.commonDirectory)

    alpha.masksName = masksName
    #expect(updated)
    #expect(registry.projects == [alpha, beta])
    #expect(registry.selection == beta.commonDirectory)
  }

  @Test("未登録への設定・解除は false で何も変えない", arguments: [false, true])
  func unknownProjectIsUnchanged(masksName: Bool) throws {
    var registry = ProjectRegistry()
    registry.register(try project(masksName: true))
    let original = registry
    let unknown = try #require(WorktreeIdentity(rawValue: "/unknown/.git"))

    #expect(registry.setMasksName(masksName, of: unknown) == false)
    #expect(registry == original)
  }

  @Test("同じ common dir を登録し直しても、既存のマスク設定を保つ")
  func duplicateRegistrationKeepsMasksName() throws {
    var registry = ProjectRegistry()
    registry.register(try project(masksName: true))

    let registration = registry.register(try project(masksName: false))

    #expect(registration == .alreadyRegistered)
    #expect(registry.projects.map(\.masksName) == [true])
  }

  @Test("伏せる Project は masksName キーに true を保存し、そのキーから復元する")
  func persistsMasksNameUnderFixedKey() throws {
    var registry = ProjectRegistry()
    registry.register(try project(masksName: true))
    let data = try JSONEncoder().encode(PersistedProjectRegistry(registry))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let projects = try #require(json["projects"] as? [[String: Any]])
    #expect(projects.first?["masksName"] as? Bool == true)

    let saved =
      #"{"schemaVersion":1,"projects":[{"commonDirectory":"/alpha/.git","directory":"/alpha","#
      + #""masksName":true}],"selection":null}"#
    let decoded = try JSONDecoder().decode(PersistedProjectRegistry.self, from: Data(saved.utf8))
    #expect(ProjectRegistry(restoring: decoded).projects.map(\.masksName) == [true])
  }

  @Test("永続化用の初期化ではマスク設定の既定値は nil")
  func persistedInitializerDefaultsToNil() throws {
    let alpha = try project()
    let persisted = PersistedRegisteredProject(
      commonDirectory: alpha.commonDirectory, directory: alpha.directory)

    #expect(persisted.masksName == nil)
  }

  @Test("保存値は nil と false を伏せない設定に、true を伏せる設定に復元する", arguments: [nil, false, true])
  func restoresMasksName(masksName: Bool?) throws {
    let alpha = try project()
    let persistedProject = PersistedRegisteredProject(
      commonDirectory: alpha.commonDirectory, directory: alpha.directory, masksName: masksName)
    let persisted = PersistedProjectRegistry(projects: [persistedProject], selection: nil)
    let restored = ProjectRegistry(restoring: persisted)

    #expect(persistedProject.masksName == masksName)
    #expect(restored.project(alpha.commonDirectory)?.masksName == (masksName == true))
  }

  @Test("JSON 経由の往復でマスク設定を保ち、schemaVersion は1のまま", arguments: [false, true])
  func roundTripPreservesMasksName(masksName: Bool) throws {
    let alpha = try project(masksName: masksName)
    var registry = ProjectRegistry()
    registry.register(alpha)

    let persisted = PersistedProjectRegistry(registry)
    let savedProject = try #require(persisted.projects.first)
    #expect(savedProject.masksName == (masksName ? true : nil))
    #expect(PersistedProjectRegistry.currentSchemaVersion == 1)
    let data = try JSONEncoder().encode(persisted)
    let decoded = try JSONDecoder().decode(PersistedProjectRegistry.self, from: data)
    let decodedProject = try #require(decoded.projects.first)
    let restored = ProjectRegistry(restoring: decoded)

    #expect(decoded.schemaVersion == 1)
    #expect(decodedProject.masksName == savedProject.masksName)
    #expect(restored.project(alpha.commonDirectory)?.masksName == masksName)
    #expect(restored == registry)
  }

  @Test("masksName キーのない既存の JSON は伏せない設定で復元する")
  func restoresLegacyJSONWithoutMasksName() throws {
    let json =
      #"{"schemaVersion":1,"projects":[{"commonDirectory":"/alpha/.git","directory":"/alpha"}],"#
      + #""selection":null}"#
    let decoded = try JSONDecoder().decode(PersistedProjectRegistry.self, from: Data(json.utf8))
    let savedProject = try #require(decoded.projects.first)
    let restored = ProjectRegistry(restoring: decoded)
    let restoredProject = try #require(restored.projects.first)

    #expect(decoded.schemaVersion == 1)
    #expect(savedProject.masksName == nil)
    #expect(restoredProject.masksName == false)
  }

  @Test("伏せない Project の JSON に masksName キーを保存しない")
  func omitsMasksNameKeyWhenUnmasked() throws {
    var registry = ProjectRegistry()
    registry.register(try project(masksName: false))
    let data = try JSONEncoder().encode(PersistedProjectRegistry(registry))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let projects = try #require(json["projects"] as? [[String: Any]])
    let savedProject = try #require(projects.first)

    #expect(savedProject.keys.contains("masksName") == false)
  }
}
