import Adapters
import Foundation
import TerminalCore
import Testing

@Suite("Application Support の保存先 (設計書 §22.1 / Issue #534)")
struct ApplicationSupportLocationTests {
  struct ResolutionCase: Sendable {
    let value: String?
    let standard: URL?
    let expected: ApplicationSupportLocation.Resolution

    init(_ value: String?, _ standard: URL?, _ expected: ApplicationSupportLocation.Resolution) {
      self.value = value
      self.standard = standard
      self.expected = expected
    }
  }

  @Test(
    "未指定・絶対パス・不正値を区別する",
    arguments: [
      ResolutionCase(
        nil, URL(fileURLWithPath: "/standard"), .standard(URL(fileURLWithPath: "/standard"))),
      ResolutionCase(
        "", URL(fileURLWithPath: "/standard"), .standard(URL(fileURLWithPath: "/standard"))),
      ResolutionCase(
        "/isolated", nil, .overridden(URL(fileURLWithPath: "/isolated", isDirectory: true))),
      ResolutionCase(
        "/isolated/", nil, .overridden(URL(fileURLWithPath: "/isolated/", isDirectory: true))),
      ResolutionCase("relative", URL(fileURLWithPath: "/standard"), .invalid(value: "relative")),
      ResolutionCase("~/x", URL(fileURLWithPath: "/standard"), .invalid(value: "~/x")),
      ResolutionCase(nil, nil, .standard(nil)),
    ]
  )
  func resolve(testCase: ResolutionCase) {
    let environment = testCase.value.map { ["AWT_APPLICATION_SUPPORT_DIR": $0] } ?? [:]

    #expect(ApplicationSupportLocation.overrideEnvironmentKey == "AWT_APPLICATION_SUPPORT_DIR")
    #expect(
      ApplicationSupportLocation.resolve(environment: environment, standard: testCase.standard)
        == testCase.expected)
  }

  @Test("上書き先の AgentWorkflowTerminal 配下に worktree inventory を置く")
  func worktreeInventoryUsesOverride() throws {
    let resolution = ApplicationSupportLocation.resolve(
      environment: ["AWT_APPLICATION_SUPPORT_DIR": "/isolated"], standard: nil)
    guard case .overridden(let directory) = resolution else {
      Issue.record("絶対パスが上書き先として解決されなかった")
      return
    }
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git"))

    let fileURL = WorktreeInventoryStore.defaultFileURL(
      applicationSupportDirectory: directory, projectRootIdentity: identity)

    #expect(fileURL.lastPathComponent == "worktree-inventory.json")
    #expect(
      fileURL.deletingLastPathComponent().deletingLastPathComponent().path
        == "/isolated/AgentWorkflowTerminal/projects")
  }

  @Test("上書き先の AgentWorkflowTerminal 配下に project registry を置く")
  func projectRegistryUsesOverride() {
    let resolution = ApplicationSupportLocation.resolve(
      environment: ["AWT_APPLICATION_SUPPORT_DIR": "/isolated"], standard: nil)
    guard case .overridden(let directory) = resolution else {
      Issue.record("絶対パスが上書き先として解決されなかった")
      return
    }

    let fileURL = ProjectRegistryStore.defaultFileURL(applicationSupportDirectory: directory)

    #expect(fileURL.path == "/isolated/AgentWorkflowTerminal/project-registry.json")
  }
}
