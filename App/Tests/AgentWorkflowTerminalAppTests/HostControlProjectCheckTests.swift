import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("hostctl の Project 登録判定 (Issue #819)")
struct HostControlProjectCheckTests {
  @Test("登録と利用可能な slot の両方が必要", arguments: [false, true])
  func registrationRequiresAvailableSlot(registered: Bool) throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let project = RegisteredProject(commonDirectory: identity, directory: "/repo")
    var registry = ProjectRegistry()
    if registered { registry.register(project) }
    let model = AppModel(
      project: project,
      dependencies: AppDependencies(
        launchProject: .none, tmuxExecutable: nil, tmuxError: nil,
        paneStates: nil, tmuxRunner: nil, paneSource: nil, signalSource: nil,
        sessionActivityProbe: nil, applicationSupportDirectory: nil, applicationSupportWarning: nil),
      notifier: nil)
    defer { model.stop() }

    let candidates: [ProjectSlot?] = [nil, .unavailable("到達できません"), .available(model)]
    for slot in candidates {
      let slots = slot.map { [identity: $0] } ?? [:]
      let result = hostControlProjectLookup(
        commonDirectory: identity, registry: registry, slots: slots)
      if registered, case .available = slot {
        guard case .available(let resolved, let resolvedModel) = result else {
          Issue.record("利用可能な登録済み Project が拒否された")
          continue
        }
        #expect(resolved == project)
        #expect(resolvedModel === model)
      } else {
        guard case .failure(let response) = result else {
          Issue.record("登録または利用可能な slot がない Project が受理された")
          continue
        }
        #expect(
          response
            == .failure(code: .notRegistered, message: "利用可能な登録済み Project が見つかりません"))
      }
    }
  }
}
