import Foundation
import TerminalCore
import Testing

@Suite("再起動を跨いだActive/Inactiveの復元 (設計書 §3.2)")
struct WorktreeInventoryRestorationTests {

  // MARK: - Helpers

  private func detected(
    _ name: String,
    path: String? = nil,
    branch: String? = nil,
    isProjectRoot: Bool = false,
    isReachable: Bool = true
  ) throws -> DetectedWorktree {
    let identityPath = isProjectRoot ? "/repo/.git" : "/repo/.git/worktrees/\(name)"
    return DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: identityPath)),
      worktreePath: path ?? (isProjectRoot ? "/repo" : "/wt/\(name)"),
      branch: branch,
      isProjectRoot: isProjectRoot,
      isReachable: isReachable
    )
  }

  private func saved(
    projectRoot: DetectedWorktree? = nil,
    _ entries: [(DetectedWorktree, WorktreeActivation)]
  ) -> PersistedWorktreeInventory {
    PersistedWorktreeInventory(
      WorktreeInventory(
        projectRoot: projectRoot,
        taskWorktrees: entries.map { TaskWorktree(detected: $0.0, activation: $0.1) }
      )
    )
  }

  private func activation(
    _ result: WorktreeScanResult,
    of identity: WorktreeIdentity
  ) -> WorktreeActivation? {
    result.inventory.taskWorktrees.first { $0.identity == identity }?.activation
  }

  // MARK: - 保存が無い場合

  @Test("保存が無い起動は初回スキャンと同じ結果になる")
  func noSavedStateBehavesAsFirstScan() throws {
    let root = try detected("root", isProjectRoot: true)
    let alpha = try detected("alpha")
    let beta = try detected("beta", isReachable: false)
    let input = [root, alpha, beta]

    let restored = restoreWorktreeInventory(detected: input, saved: nil)

    #expect(restored == reconcileDetectedWorktrees(detected: input, previous: nil))
  }

  // MARK: - 引き継ぎ

  @Test("保存されたActiveは再検出時もActiveのまま復元する")
  func savedActivationSurvivesRestart() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")

    let restored = restoreWorktreeInventory(
      detected: [alpha, beta],
      saved: saved([(alpha, .active), (beta, .inactive)])
    )

    #expect(activation(restored, of: alpha.identity) == .active)
    #expect(activation(restored, of: beta.identity) == .inactive)
    #expect(restored.appeared.isEmpty)
    #expect(restored.disappeared.isEmpty)
  }

  @Test("停止中に現れたworktreeはInactiveから始め、新規出現として数えない")
  func worktreeAppearingWhileAppWasDownStartsInactive() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")

    let restored = restoreWorktreeInventory(
      detected: [alpha, beta],
      saved: saved([(alpha, .active)])
    )

    #expect(activation(restored, of: beta.identity) == .inactive)
    #expect(restored.appeared.isEmpty)
  }

  @Test("停止中に消えたworktreeは保存されたActiveのまま到達不能として残す")
  func worktreeDisappearingWhileAppWasDownIsRetained() throws {
    let alpha = try detected("alpha")
    let gone = try detected("gone", path: "/wt/gone", branch: "feat/gone")

    let restored = restoreWorktreeInventory(
      detected: [alpha],
      saved: saved([(alpha, .inactive), (gone, .active)])
    )

    let retained = try #require(
      restored.inventory.taskWorktrees.first { $0.identity == gone.identity }
    )
    #expect(retained.activation == .active)
    #expect(retained.detected.isReachable == false)
    #expect(retained.detected.worktreePath == "/wt/gone")
    #expect(retained.detected.branch == "feat/gone")
    #expect(restored.disappeared.isEmpty)
  }

  @Test("消えて戻ってきたActive worktreeはActiveのまま復元し、新規出現にしない")
  func returningWorktreeKeepsSavedActivation() throws {
    let alpha = try detected("alpha")
    let savedState = saved([(alpha, .active)])

    let whileGone = restoreWorktreeInventory(detected: [], saved: savedState)
    let afterReturn = restoreWorktreeInventory(
      detected: [alpha],
      saved: PersistedWorktreeInventory(whileGone.inventory)
    )

    #expect(activation(afterReturn, of: alpha.identity) == .active)
    #expect(afterReturn.inventory.taskWorktrees.map(\.detected.isReachable) == [true])
    #expect(afterReturn.appeared.isEmpty)
  }

  @Test("検出値がパスとbranchを上書きし、保存値はactivationだけを供給する")
  func detectionSuppliesPathAndBranch() throws {
    let savedAlpha = try detected("alpha", path: "/old/alpha", branch: "old")
    let movedAlpha = try detected("alpha", path: "/new/alpha", branch: "new")

    let restored = restoreWorktreeInventory(
      detected: [movedAlpha],
      saved: saved([(savedAlpha, .active)])
    )

    #expect(restored.inventory.taskWorktrees.map(\.detected) == [movedAlpha])
    #expect(activation(restored, of: movedAlpha.identity) == .active)
  }

  // MARK: - Project Root

  @Test("保存されたProject Rootが検出できなければ到達不能として残す")
  func missingProjectRootIsRetainedAsUnreachable() throws {
    let root = try detected("root", isProjectRoot: true)
    let alpha = try detected("alpha")

    let restored = restoreWorktreeInventory(
      detected: [alpha],
      saved: saved(projectRoot: root, [(alpha, .active)])
    )

    let retained = try #require(restored.inventory.projectRoot)
    #expect(retained.identity == root.identity)
    #expect(retained.isProjectRoot)
    #expect(retained.isReachable == false)
    #expect(retained.worktreePath == root.worktreePath)
    #expect(restored.disappeared.isEmpty)
  }

  @Test("保存でProject Rootだった安定IDがTaskとして現れたらInactiveから始める")
  func projectRootDemotedToTaskStartsInactive() throws {
    let root = try detected("root", isProjectRoot: true)
    let demoted = DetectedWorktree(
      identity: root.identity,
      worktreePath: root.worktreePath,
      branch: nil,
      isProjectRoot: false
    )

    let restored = restoreWorktreeInventory(
      detected: [demoted],
      saved: saved(projectRoot: root, [])
    )

    #expect(activation(restored, of: root.identity) == .inactive)
    #expect(restored.inventory.projectRoot == nil)
    #expect(restored.appeared.isEmpty)
  }

  @Test("保存でTaskだった安定IDがProject Rootとして現れたらTask側へ二重に残さない")
  func taskPromotedToProjectRootIsNotDuplicated() throws {
    let alpha = try detected("alpha")
    let promoted = DetectedWorktree(
      identity: alpha.identity,
      worktreePath: alpha.worktreePath,
      branch: alpha.branch,
      isProjectRoot: true
    )

    let restored = restoreWorktreeInventory(
      detected: [promoted],
      saved: saved([(alpha, .active)])
    )

    #expect(restored.inventory.projectRoot == promoted)
    #expect(restored.inventory.taskWorktrees.isEmpty)
  }

  // MARK: - 重複

  @Test("同じ安定IDが複数渡された場合は最初の1件だけを採る")
  func duplicateIdentitiesKeepFirstOccurrence() throws {
    let first = try detected("alpha", path: "/wt/first")
    let second = try detected("alpha", path: "/wt/second")

    let restored = restoreWorktreeInventory(
      detected: [first, second],
      saved: saved([(first, .active)])
    )

    #expect(restored.inventory.taskWorktrees.map(\.detected) == [first])
  }

  @Test("保存側に同じ安定IDが複数あれば最初の1件のactivationを採る")
  func duplicateSavedIdentitiesKeepFirstOccurrence() throws {
    let alpha = try detected("alpha")
    let conflicting = PersistedWorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [
        PersistedTaskWorktree(
          identity: alpha.identity, worktreePath: "/wt/first", branch: "first", activation: .active),
        PersistedTaskWorktree(
          identity: alpha.identity, worktreePath: "/wt/second", branch: "second",
          activation: .inactive),
      ]
    )

    let whileDetected = restoreWorktreeInventory(detected: [alpha], saved: conflicting)
    let whileMissing = restoreWorktreeInventory(detected: [], saved: conflicting)

    #expect(whileDetected.inventory.taskWorktrees.map(\.activation) == [.active])
    #expect(whileMissing.inventory.taskWorktrees.map(\.activation) == [.active])
    #expect(whileMissing.inventory.taskWorktrees.map(\.detected.worktreePath) == ["/wt/first"])
  }

  // MARK: - 壊れた保存ファイル

  @Test("同じ安定IDがProject RootとTaskの両方にある保存はProject Root側だけを復元する")
  func identityInBothFieldsIsRestoredOnlyAsProjectRoot() throws {
    let root = try detected("root", isProjectRoot: true)
    let corrupted = PersistedWorktreeInventory(
      projectRoot: PersistedProjectRootWorktree(
        identity: root.identity, worktreePath: root.worktreePath, branch: nil),
      taskWorktrees: [
        PersistedTaskWorktree(
          identity: root.identity, worktreePath: root.worktreePath, branch: nil,
          activation: .active)
      ]
    )

    let restored = restoreWorktreeInventory(detected: [], saved: corrupted)

    #expect(restored.inventory.projectRoot?.identity == root.identity)
    #expect(restored.inventory.taskWorktrees.isEmpty)
  }

  @Test("Project Root側が復元されなければ、両方に載った安定IDはTaskとして復活する")
  func identityInBothFieldsRevivesAsTaskWhenProjectRootIsTakenByAnother() throws {
    let root = try detected("root", isProjectRoot: true)
    let otherRoot = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/other/.git")),
      worktreePath: "/other",
      branch: nil,
      isProjectRoot: true
    )
    let corrupted = PersistedWorktreeInventory(
      projectRoot: PersistedProjectRootWorktree(
        identity: root.identity, worktreePath: root.worktreePath, branch: nil),
      taskWorktrees: [
        PersistedTaskWorktree(
          identity: root.identity, worktreePath: root.worktreePath, branch: nil,
          activation: .active)
      ]
    )

    let restored = restoreWorktreeInventory(detected: [otherRoot], saved: corrupted)

    #expect(restored.inventory.projectRoot == otherRoot)
    #expect(restored.inventory.taskWorktrees.map(\.identity) == [root.identity])
    #expect(restored.inventory.taskWorktrees.map(\.activation) == [.active])
  }

  @Test("isProjectRootが複数あれば最初の1件だけをProject Rootとし、残りは捨てる")
  func duplicateProjectRootsKeepFirstOccurrence() throws {
    let first = try detected("root", isProjectRoot: true)
    let second = DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/other/.git")),
      worktreePath: "/other",
      branch: nil,
      isProjectRoot: true
    )

    let restored = restoreWorktreeInventory(
      detected: [first, second],
      saved: saved(projectRoot: first, [])
    )

    #expect(restored.inventory.projectRoot == first)
    #expect(restored.inventory.taskWorktrees.isEmpty)
  }

  // MARK: - 順序

  @Test("検出順のあとに保存だけにあるものを保存順で並べる")
  func orderingIsDeterministic() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")
    let goneOne = try detected("gone1")
    let goneTwo = try detected("gone2")

    let restored = restoreWorktreeInventory(
      detected: [beta, alpha],
      saved: saved([(goneOne, .active), (alpha, .active), (goneTwo, .inactive)])
    )

    #expect(
      restored.inventory.taskWorktrees.map(\.identity) == [
        beta.identity, alpha.identity, goneOne.identity, goneTwo.identity,
      ])
  }

  // MARK: - 観測中の差分計算との接続

  @Test("復元した状態を前回状態として渡すと、以後の新規出現は自動Active化される")
  func restoredInventoryFeedsIncrementalReconciliation() throws {
    let alpha = try detected("alpha")
    let beta = try detected("beta")

    let restored = restoreWorktreeInventory(detected: [alpha], saved: saved([(alpha, .active)]))
    let next = reconcileDetectedWorktrees(
      detected: [alpha, beta],
      previous: restored.inventory
    )

    #expect(activation(next, of: alpha.identity) == .active)
    #expect(activation(next, of: beta.identity) == .active)
    #expect(next.appeared == [beta.identity])
  }

  // MARK: - 符号化

  @Test("JSONを経由してもactivationが保存される")
  func activationSurvivesJSONRoundTrip() throws {
    let root = try detected("root", isProjectRoot: true)
    let alpha = try detected("alpha", branch: "feat/alpha")
    let beta = try detected("beta")
    let inventory = WorktreeInventory(
      projectRoot: root,
      taskWorktrees: [
        TaskWorktree(detected: alpha, activation: .active),
        TaskWorktree(detected: beta, activation: .inactive),
      ]
    )

    let encoded = try JSONEncoder().encode(PersistedWorktreeInventory(inventory))
    let decoded = try JSONDecoder().decode(PersistedWorktreeInventory.self, from: encoded)
    let restored = restoreWorktreeInventory(detected: [root, alpha, beta], saved: decoded)

    #expect(decoded.schemaVersion == PersistedWorktreeInventory.currentSchemaVersion)
    #expect(restored.inventory == inventory)
  }

  @Test("到達可能性は保存しない")
  func reachabilityIsNotPersisted() throws {
    let alpha = try detected("alpha", isReachable: false)
    let inventory = WorktreeInventory(
      projectRoot: nil,
      taskWorktrees: [TaskWorktree(detected: alpha, activation: .active)]
    )

    let encoded = try JSONEncoder().encode(PersistedWorktreeInventory(inventory))
    let text = String(decoding: encoded, as: UTF8.self)

    #expect(!text.contains("isReachable"))
    #expect(!text.contains("Reachable"))
    #expect(!text.contains("isProjectRoot"))
  }
}
