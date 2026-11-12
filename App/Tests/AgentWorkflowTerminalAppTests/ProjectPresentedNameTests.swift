import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("Project の表示名")
struct ProjectPresentedNameTests {
  @Test("名前を伏せる設定に応じた表示名を返す", arguments: [false, true])
  func presentedName(masksName: Bool) throws {
    let project = RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/agent-workflow-terminal/.git")),
      directory: "/agent-workflow-terminal", masksName: masksName)

    #expect(project.presentedName == (masksName ? "a•••" : "agent-workflow-terminal"))
    #expect(project.displayName == "agent-workflow-terminal")
  }
}
