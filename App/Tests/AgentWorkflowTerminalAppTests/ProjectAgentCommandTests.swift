import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("Agent 起動コマンドの検証と保存")
struct ProjectAgentCommandTests {
  @Test(
    "不正な保存値ではセッションを開かず、修正用に値を残す",
    arguments: [
      "agent\n--option", "agent\u{0000}option", String(repeating: "a", count: 151),
    ])
  func rejectsInvalidSavedCommand(input: String) async throws {
    let project = try makeProject(command: input)
    var registry = ProjectRegistry()
    registry.register(project)
    let original = registry
    var didOpen = false

    let response = await openWorktreeWithValidatedAgentCommand(
      agentCommand: registry.project(project.commonDirectory)?.agentCommand,
      open: {
        didOpen = true
        return opened()
      },
      isRegistered: { registry.project(project.commonDirectory) != nil })

    #expect(!didOpen)
    #expect(registry == original)
    #expect(
      response
        == .failure(
          code: .invalidRequest,
          message: "保存された Agent 起動コマンドが不正です。Project の設定で直してください"))
  }

  @Test("処理中に登録解除されたら成功を返さない")
  func rejectsUnregisteredProject() async throws {
    let project = try makeProject(command: "agent")
    var registry = ProjectRegistry()
    registry.register(project)

    let response = await openWorktreeWithValidatedAgentCommand(
      agentCommand: project.agentCommand,
      open: {
        await Task.yield()
        registry.unregister(project.commonDirectory)
        return opened()
      },
      isRegistered: { registry.project(project.commonDirectory) != nil })

    #expect(
      response == .failure(code: .notRegistered, message: "処理中に Project の登録が解除されました"))
  }

  @Test("応答には処理開始前に正規化した値を使う", arguments: [nil, " \u{200B} ", " agent --option "])
  func returnsValidatedSnapshot(command: String?) async throws {
    let project = try makeProject(command: command)
    var registry = ProjectRegistry()
    registry.register(project)
    var didOpen = false

    let response = await openWorktreeWithValidatedAgentCommand(
      agentCommand: project.agentCommand,
      open: {
        didOpen = true
        await Task.yield()
        registry.setAgentCommand("changed\ninvalid", of: project.commonDirectory)
        return opened()
      },
      isRegistered: { registry.project(project.commonDirectory) != nil })

    #expect(didOpen)
    #expect(response == opened(command: command == " agent --option " ? "agent --option" : nil))
  }

  @Test("セッションを開けなかった理由を維持する")
  func preservesOpeningFailure() async {
    let failure = HostControlResponse.failure(code: .tmuxFailed, message: "作成できません")
    let response = await openWorktreeWithValidatedAgentCommand(
      agentCommand: "agent", open: { failure }, isRegistered: { true })
    #expect(response == failure)
  }

  @Test(
    "一覧を保存できないときは入力にかかわらず registry を変えない",
    arguments: [
      "new-agent", "", "agent\ninvalid",
    ])
  func cannotSavePreservesRegistry(input: String) throws {
    let project = try makeProject(command: "original-agent")
    var registry = ProjectRegistry()
    registry.register(project)
    let original = registry

    let error = setProjectAgentCommand(
      input, of: project.commonDirectory, canSave: false, registry: &registry)

    #expect(error == .cannotSave)
    #expect(registry == original)
  }

  @Test("不正な入力の保存は失敗し registry を変えない")
  func invalidSavePreservesRegistry() throws {
    let project = try makeProject(command: "original-agent")
    var registry = ProjectRegistry()
    registry.register(project)
    let original = registry

    let error = setProjectAgentCommand(
      "agent\ninvalid", of: project.commonDirectory, canSave: true, registry: &registry)

    #expect(error == .invalid(.containsControlCharacter))
    #expect(registry == original)
  }

  @Test("保存可能なら正規化した値で更新し空入力なら解除する", arguments: [" new-agent ", ""])
  func updatesCommand(input: String) throws {
    let project = try makeProject(command: "original-agent")
    var registry = ProjectRegistry()
    registry.register(project)

    let error = setProjectAgentCommand(
      input, of: project.commonDirectory, canSave: true, registry: &registry)

    #expect(error == nil)
    #expect(
      registry.project(project.commonDirectory)?.agentCommand == (input.isEmpty ? nil : "new-agent")
    )
  }

  private func makeProject(command: String?) throws -> RegisteredProject {
    RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/repo/.git")),
      directory: "/repo", agentCommand: command)
  }

  private func opened(command: String? = nil) -> HostControlResponse {
    .opened(
      HostControlOpenedWorktree(
        session: "session", directory: "/repo/task", created: true, agentCommand: command))
  }
}
