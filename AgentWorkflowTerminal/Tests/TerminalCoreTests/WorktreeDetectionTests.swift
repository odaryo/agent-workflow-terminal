import TerminalCore
import Testing

@Suite("worktree検出とActive/Inactiveの差分計算 (設計書 §3.2)")
struct WorktreeDetectionTests {

  // MARK: - Helpers

  private func detected(
    _ name: String,
    branch: String? = nil,
    isProjectRoot: Bool = false
  ) throws -> DetectedWorktree {
    let path = isProjectRoot ? "/repo/.git" : "/repo/.git/worktrees/\(name)"
    return DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: path)),
      worktreePath: isProjectRoot ? "/repo" : "/wt/\(name)",
      branch: branch,
      isProjectRoot: isProjectRoot
    )
  }

  private func inventory(
    projectRoot: DetectedWorktree? = nil,
    _ entries: [(DetectedWorktree, WorktreeActivation)]
  ) -> WorktreeInventory {
    WorktreeInventory(
      projectRoot: projectRoot,
      taskWorktrees: entries.map { TaskWorktree(detected: $0.0, activation: $0.1) }
    )
  }

  // MARK: - 初回スキャン

  @Test("初回スキャンでは全worktreeをInactiveから始める")
  func firstScanStartsInactive() throws {
    let root = try detected("root", isProjectRoot: true)
    let alpha = try detected("alpha")
    let beta = try detected("beta")

    let result = reconcileDetectedWorktrees(detected: [root, alpha, beta], previous: nil)

    #expect(result.inventory.taskWorktrees.map(\.activation) == [.inactive, .inactive])
    #expect(result.appeared.isEmpty)
    #expect(result.disappeared.isEmpty)
  }

  @Test("初回スキャンと「前回状態が空」は別物で、後者では新規出現として自動Active化する")
  func emptyPreviousStateDiffersFromNoPreviousState() throws {
    let alpha = try detected("alpha")

    let firstScan = reconcileDetectedWorktrees(detected: [alpha], previous: nil)
    let afterEmpty = reconcileDetectedWorktrees(
      detected: [alpha],
      previous: inventory([])
    )

    #expect(firstScan.inventory.taskWorktrees.map(\.activation) == [.inactive])
    #expect(firstScan.appeared.isEmpty)
    #expect(afterEmpty.inventory.taskWorktrees.map(\.activation) == [.active])
    #expect(afterEmpty.appeared == [alpha.identity])
  }

  // MARK: - Project Root (§2.3)

  @Test("Project RootはTask worktreeと別枠で返し、Active/Inactiveを持たせない")
  func projectRootIsSeparatedFromTaskWorktrees() throws {
    let root = try detected("root", branch: "main", isProjectRoot: true)
    let alpha = try detected("alpha")

    let result = reconcileDetectedWorktrees(detected: [root, alpha], previous: nil)

    #expect(result.inventory.projectRoot == root)
    #expect(result.inventory.taskWorktrees.map(\.identity) == [alpha.identity])
  }

  @Test("Project Rootが検出されなければ projectRoot は nil になる")
  func missingProjectRootIsNil() throws {
    let alpha = try detected("alpha")

    let result = reconcileDetectedWorktrees(detected: [alpha], previous: nil)

    #expect(result.inventory.projectRoot == nil)
  }

  @Test("Project Rootが消えたら消失として返す")
  func disappearedProjectRootIsReported() throws {
    let root = try detected("root", isProjectRoot: true)
    let alpha = try detected("alpha")

    let result = reconcileDetectedWorktrees(
      detected: [alpha],
      previous: inventory(projectRoot: root, [(alpha, .active)])
    )

    #expect(result.inventory.projectRoot == nil)
    #expect(result.disappeared == [root.identity])
  }

  @Test("2件目以降のProject Rootは捨て、Task worktreeへ格下げしない")
  func extraProjectRootIsDropped() throws {
    let root = try detected("root", isProjectRoot: true)
    let impostor = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/other/.git")),
      worktreePath: "/other",
      branch: nil,
      isProjectRoot: true
    )

    let result = reconcileDetectedWorktrees(detected: [root, impostor], previous: nil)

    #expect(result.inventory.projectRoot == root)
    #expect(result.inventory.taskWorktrees.isEmpty)
  }

  // MARK: - 2回目以降の差分

  @Test("観測中に新しく現れたworktreeは自動的にActive化する")
  func newlyAppearedWorktreeIsActivated() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")

    let result = reconcileDetectedWorktrees(
      detected: [alpha, beta],
      previous: inventory([(alpha, .inactive)])
    )

    #expect(result.appeared == [beta.identity])
    #expect(result.inventory.taskWorktrees.map(\.activation) == [.inactive, .active])
  }

  @Test(
    "前回状態にあるworktreeのActive/Inactiveはそのまま維持する",
    arguments: [WorktreeActivation.active, .inactive]
  )
  func knownWorktreeKeepsItsActivation(activation: WorktreeActivation) throws {
    let alpha = try detected("alpha")

    let result = reconcileDetectedWorktrees(
      detected: [alpha],
      previous: inventory([(alpha, activation)])
    )

    #expect(result.inventory.taskWorktrees.map(\.activation) == [activation])
    #expect(result.appeared.isEmpty)
  }

  @Test("branchや作業ツリーのパスが変わっても、安定IDが同じなら既存として扱う")
  func identityIsTheOnlyKey() throws {
    let before = try detected("alpha", branch: "feat/a")
    let after = DetectedWorktree(
      identity: before.identity,
      worktreePath: "/moved/alpha",
      branch: "feat/renamed",
      isProjectRoot: false
    )

    let result = reconcileDetectedWorktrees(
      detected: [after],
      previous: inventory([(before, .active)])
    )

    #expect(result.appeared.isEmpty)
    #expect(result.inventory.taskWorktrees.map(\.detected) == [after])
    #expect(result.inventory.taskWorktrees.map(\.activation) == [.active])
  }

  @Test("前回Project Rootだったidentityがtask worktreeとして現れても新規扱いしない")
  func formerProjectRootIsNotTreatedAsNew() throws {
    let root = try detected("root", isProjectRoot: true)
    let demoted = DetectedWorktree(
      identity: root.identity,
      worktreePath: root.worktreePath,
      branch: root.branch,
      isProjectRoot: false
    )

    let result = reconcileDetectedWorktrees(
      detected: [demoted],
      previous: inventory(projectRoot: root, [])
    )

    #expect(result.appeared.isEmpty)
    #expect(result.inventory.taskWorktrees.map(\.activation) == [.inactive])
  }

  // MARK: - 消失

  @Test("前回あって今回無いworktreeは消失として返し、一覧からは外す")
  func disappearedWorktreeIsRemoved() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")

    let result = reconcileDetectedWorktrees(
      detected: [alpha],
      previous: inventory([(alpha, .active), (beta, .inactive)])
    )

    #expect(result.disappeared == [beta.identity])
    #expect(result.inventory.taskWorktrees.map(\.identity) == [alpha.identity])
  }

  @Test("消失は前回状態の順で返す")
  func disappearedKeepsPreviousOrder() throws {
    let root = try detected("root", isProjectRoot: true)
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")

    let previous = inventory(
      projectRoot: root,
      [(gamma, .active), (alpha, .inactive), (beta, .active)]
    )

    let result = reconcileDetectedWorktrees(detected: [], previous: previous)

    #expect(
      result.disappeared == [root.identity, gamma.identity, alpha.identity, beta.identity]
    )
  }

  // MARK: - 決定性

  @Test("Task worktreeは検出順で返す")
  func taskWorktreesKeepDetectionOrder() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")

    let result = reconcileDetectedWorktrees(detected: [gamma, alpha, beta], previous: nil)

    #expect(
      result.inventory.taskWorktrees.map(\.identity)
        == [gamma.identity, alpha.identity, beta.identity]
    )
  }

  @Test("同じidentityが重複して検出されたら最初の1件だけを採る")
  func duplicateIdentityKeepsTheFirstOccurrence() throws {
    let first = try detected("alpha", branch: "feat/a")
    let duplicate = DetectedWorktree(
      identity: first.identity,
      worktreePath: "/wt/duplicate",
      branch: "feat/duplicate",
      isProjectRoot: false
    )

    let result = reconcileDetectedWorktrees(detected: [first, duplicate], previous: nil)

    #expect(result.inventory.taskWorktrees.map(\.detected) == [first])
  }

  @Test("新規出現も検出順で返す")
  func appearedKeepsDetectionOrder() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let gamma = try detected("gamma")

    let result = reconcileDetectedWorktrees(
      detected: [gamma, alpha, beta],
      previous: inventory([(alpha, .inactive)])
    )

    #expect(result.appeared == [gamma.identity, beta.identity])
  }
}
