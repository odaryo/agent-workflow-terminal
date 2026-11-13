import TerminalCore
import Testing

@Suite("登録済み Project の並べ替え (設計書 §13)")
struct ProjectRegistryReorderTests {

  // MARK: - Helpers

  private func project(_ name: String, directory: String? = nil) throws -> RegisteredProject {
    RegisteredProject(
      commonDirectory: try #require(WorktreeIdentity(rawValue: "/\(name)/.git")),
      directory: directory ?? "/\(name)"
    )
  }

  private func registry(_ projects: [RegisteredProject]) -> ProjectRegistry {
    var registry = ProjectRegistry()
    for project in projects {
      registry.register(project)
    }
    return registry
  }

  // MARK: - 並べ替え (設計書 §13)

  @Test(
    "移動後の index を指定して後方・前方・中ほどへ移すと true を返す",
    arguments: [
      (0, 2, [1, 2, 0]),
      (2, 0, [2, 0, 1]),
      (0, 1, [1, 0, 2]),
      (2, 1, [0, 2, 1]),
    ])
  func moveProjectUsesFinalIndex(source: Int, destination: Int, expectedIndices: [Int]) throws {
    let projects = try [project("alpha"), project("beta"), project("gamma")]
    var registry = self.registry(projects)

    let changed = registry.moveProject(projects[source].commonDirectory, to: destination)

    #expect(changed)
    #expect(registry.projects == expectedIndices.map { projects[$0] })
  }

  @Test("同じ位置への移動は false を返し、一覧と選択を変えない", arguments: [0, 1, 2])
  func moveProjectToCurrentIndexIsNoOp(index: Int) throws {
    let projects = try [project("alpha"), project("beta"), project("gamma")]
    var registry = self.registry(projects)
    let original = registry

    let changed = registry.moveProject(projects[index].commonDirectory, to: index)

    #expect(changed == false)
    #expect(registry == original)
  }

  @Test("未登録の Project の移動は false を返し、一覧と選択を変えない")
  func moveUnknownProjectIsNoOp() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    var registry = self.registry([alpha, beta])
    let original = registry

    let changed = registry.moveProject(try project("unknown").commonDirectory, to: 0)

    #expect(changed == false)
    #expect(registry == original)
  }

  @Test("負または count 以上の移動先は false を返し、一覧と選択を変えない", arguments: [-1, 3, 4])
  func moveProjectToInvalidIndexIsNoOp(destination: Int) throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let gamma = try project("gamma")
    var registry = self.registry([alpha, beta, gamma])
    let original = registry

    let changed = registry.moveProject(alpha.commonDirectory, to: destination)

    #expect(changed == false)
    #expect(registry == original)
  }

  @Test("選択中または別の Project を動かしても選択を保つ", arguments: [true, false])
  func moveProjectKeepsSelection(movesSelectedProject: Bool) throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let gamma = try project("gamma")
    var registry = self.registry([alpha, beta, gamma])
    let selected = movesSelectedProject ? alpha.commonDirectory : beta.commonDirectory
    registry.select(selected)

    let changed = registry.moveProject(alpha.commonDirectory, to: 2)

    #expect(changed)
    #expect(registry.projects == [beta, gamma, alpha])
    #expect(registry.selection == selected)
  }

  @Test("動かした Project の directory・agentCommand・masksName を保つ", arguments: [true, false])
  func moveProjectKeepsSettings(masksName: Bool) throws {
    var alpha = try project("alpha", directory: "/alpha-worktree")
    alpha.agentCommand = "codex --model example"
    alpha.masksName = masksName
    let beta = try project("beta")
    let gamma = try project("gamma")
    var registry = self.registry([alpha, beta, gamma])

    let changed = registry.moveProject(alpha.commonDirectory, to: 2)

    #expect(changed)
    #expect(registry.projects == [beta, gamma, alpha])
    #expect(registry.project(alpha.commonDirectory) == alpha)
  }

  @Test("並べ替えた順で隣の Project を前方・後方へ巡回する", arguments: [true, false])
  func adjacentSelectionFollowsReorderedProjects(forward: Bool) throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let gamma = try project("gamma")
    var registry = self.registry([alpha, beta, gamma])
    let moved = registry.moveProject(beta.commonDirectory, to: 2)
    try #require(moved)
    registry.select(alpha.commonDirectory)
    let expected = forward ? [gamma, beta, alpha] : [beta, gamma, alpha]

    for project in expected {
      let original = registry
      let candidate = registry.adjacentSelection(forward: forward) { _ in true }

      #expect(candidate == project.commonDirectory)
      #expect(registry == original)
      registry.select(try #require(candidate))
    }
  }

  @Test("保存形式との往復で並べ替えた順と選択を保つ")
  func reorderedRegistryRoundTripsThroughPersistedForm() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let gamma = try project("gamma")
    var registry = self.registry([alpha, beta, gamma])
    registry.select(beta.commonDirectory)
    let moved = registry.moveProject(beta.commonDirectory, to: 2)
    try #require(moved)

    let persisted = PersistedProjectRegistry(registry)
    let restored = ProjectRegistry(restoring: persisted)

    #expect(persisted.projects == [alpha, gamma, beta].map(PersistedRegisteredProject.init))
    #expect(restored.projects == [alpha, gamma, beta])
    #expect(restored.selection == beta.commonDirectory)
    #expect(restored == registry)
  }

  @Test("並べ替えた後に登録した Project は末尾に入る")
  func registerAppendsAfterReordering() throws {
    let alpha = try project("alpha")
    let beta = try project("beta")
    let gamma = try project("gamma")
    let delta = try project("delta")
    var registry = self.registry([alpha, beta, gamma])
    let moved = registry.moveProject(beta.commonDirectory, to: 2)
    try #require(moved)

    let registration = registry.register(delta)

    #expect(registration == .added)
    #expect(registry.projects == [alpha, gamma, beta, delta])
    #expect(registry.selection == delta.commonDirectory)
  }
}
