import Foundation
import TerminalCore
import Testing

@Suite("Project ごとの Agent 起動コマンド (設計書 §3.1)")
struct ProjectAgentCommandTests {
  @Test("上限は UTF-8 で150バイト")
  func maximumLengthIs150UTF8Bytes() {
    #expect(ProjectAgentCommand.maximumUTF8Bytes == 150)
  }

  @Test("空文字と空白・改行だけなら未設定", arguments: ["", "   ", "\n", " \n\r\t "])
  func blankInputIsUnset(input: String) {
    #expect(ProjectAgentCommand.normalized(input) == .success(nil))
  }

  @Test(
    "前後の空白と改行を除き、内部の空白を保つ",
    arguments: [
      "claude --model fable", "  claude --model fable  ", "\n\tclaude --model fable\r\n",
    ])
  func trimsSurroundingWhitespace(input: String) {
    #expect(ProjectAgentCommand.normalized(input) == .success("claude --model fable"))
  }

  @Test(
    "内部の Unicode Cc 制御文字は拒否する",
    arguments: [
      "\n", "\t", "\0", "\r", "\u{001B}", "\u{007F}", "\u{0080}",
    ])
  func rejectsInternalControlCharacters(control: String) {
    #expect(
      ProjectAgentCommand.normalized("claude\(control)--model fable")
        == .failure(.containsControlCharacter)
    )
  }

  @Test(
    "150バイトちょうどは成功する",
    arguments: [
      String(repeating: "a", count: 150), String(repeating: "あ", count: 50),
    ])
  func acceptsExactly150Bytes(input: String) {
    #expect(ProjectAgentCommand.normalized(input) == .success(input))
  }

  @Test(
    "151バイトは文字数によらず拒否する",
    arguments: [
      String(repeating: "a", count: 151), String(repeating: "あ", count: 50) + "a",
    ])
  func rejects151Bytes(input: String) {
    #expect(ProjectAgentCommand.normalized(input) == .failure(.tooLong(maximumUTF8Bytes: 150)))
  }

  @Test("長さは前後の空白と改行を除いた後で判定する")
  func measuresLengthAfterTrimming() {
    let command = String(repeating: "a", count: 150)

    #expect(ProjectAgentCommand.normalized(" \n\(command)\r ") == .success(command))
  }
}

@Suite("Project の Agent 起動コマンドの登録と永続化 (設計書 §3.1)")
struct ProjectAgentCommandRegistryTests {
  private func project(agentCommand: String? = nil) throws -> RegisteredProject {
    RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/alpha/.git")),
      directory: "/alpha",
      agentCommand: agentCommand
    )
  }

  @Test("初期化で起動コマンドを保持し、省略時は未設定")
  func initializerPreservesAgentCommand() throws {
    #expect(try project(agentCommand: "codex").agentCommand == "codex")
    #expect(try project().agentCommand == nil)
  }

  @Test(
    "登録済み Project のコマンドを設定・変更できる",
    arguments: ["codex", "claude --model fable"], [nil, "previous-command"])
  func setsAgentCommand(command: String, previousCommand: String?) throws {
    var alpha = try project()
    alpha.agentCommand = previousCommand
    let beta = RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/beta/.git")), directory: "/beta")
    var registry = ProjectRegistry()
    registry.register(alpha)
    registry.register(beta)

    let updated = registry.setAgentCommand(command, of: alpha.commonDirectory)

    alpha.agentCommand = command
    #expect(updated)
    #expect(registry.projects == [alpha, beta])
    #expect(registry.selection == beta.commonDirectory)
  }

  @Test("nil で起動コマンドを解除できる")
  func clearsAgentCommand() throws {
    var alpha = try project()
    alpha.agentCommand = "codex"
    var registry = ProjectRegistry()
    registry.register(alpha)

    let updated = registry.setAgentCommand(nil, of: alpha.commonDirectory)

    #expect(updated)
    #expect(registry.project(alpha.commonDirectory)?.agentCommand == nil)
    #expect(registry.projects.count == 1)
    #expect(registry.selection == alpha.commonDirectory)
  }

  @Test("未登録への設定・解除は false で一覧と選択を変えない", arguments: ["codex", nil])
  func unknownProjectIsUnchanged(command: String?) throws {
    var registry = ProjectRegistry()
    registry.register(try project())
    let original = registry
    let unknown = try #require(WorktreeIdentity(rawValue: "/unknown/.git"))

    #expect(registry.setAgentCommand(command, of: unknown) == false)
    #expect(registry == original)
  }

  @Test("設定ありの Project を JSON 経由で往復してもコマンドを保持する")
  func roundTripPreservesAgentCommand() throws {
    var alpha = try project()
    alpha.agentCommand = "claude --model fable"
    var registry = ProjectRegistry()
    registry.register(alpha)

    let persisted = PersistedProjectRegistry(registry)
    #expect(persisted.projects.first?.agentCommand == "claude --model fable")
    let data = try JSONEncoder().encode(persisted)
    let decoded = try JSONDecoder().decode(PersistedProjectRegistry.self, from: data)

    #expect(decoded.projects.first?.agentCommand == "claude --model fable")
    #expect(decoded.schemaVersion == 1)
    #expect(ProjectRegistry(restoring: decoded) == registry)
  }

  @Test("永続化用の初期化で指定したコマンドを保持する")
  func persistedInitializerPreservesAgentCommand() throws {
    let alpha = try project()
    let persisted = PersistedRegisteredProject(
      commonDirectory: alpha.commonDirectory, directory: alpha.directory, agentCommand: "codex")

    #expect(persisted.agentCommand == "codex")
  }

  @Test("JSON に保存されたコマンドを登録済み Project に復元する")
  func restoresAgentCommandFromJSON() throws {
    let json =
      #"{"projects":[{"commonDirectory":"/alpha/.git","directory":"/alpha","agentCommand":"codex"}],"#
      + #""schemaVersion":1,"selection":"/alpha/.git"}"#
    let persisted = try JSONDecoder().decode(PersistedProjectRegistry.self, from: Data(json.utf8))

    #expect(persisted.projects.first?.agentCommand == "codex")
    #expect(ProjectRegistry(restoring: persisted).projects.first?.agentCommand == "codex")
  }
}
