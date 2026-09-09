import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// Issue #239 の回帰テスト。10 pane / 5 worktree を App と同じ周期で観測したとき、外部プロセス
/// 起動が pane 数・worktree 数に線形へ戻っていないことを、起動回数の**上限**として主張する。
///
/// 実時計には依存させない (時刻は `ManualTimeSource`)。CPU はここでは数えず、隔離 socket の
/// 実測に任せる。
@Suite("状態観測の外部プロセス起動予算")
struct ObservationLaunchBudgetTests {
  /// App の配線と同じ値 (`AgentObservationIntervals(signals: 2s, liveness: 5s)` /
  /// `paneListInterval` 2s)。`signals` と pane 一覧が同じ 2s なので tick は1つで足りる。
  private static let tickInterval = Duration.seconds(2)
  private static let worktreeCount = 5
  private static let panesPerWorktree = 2
  private static let tickCount = 10
  private static let expectedPaneCount = worktreeCount * panesPerWorktree

  @Test("10 pane を 20 秒ぶん観測しても起動は 80 回を大きく下回る")
  func staysWithinLaunchBudget() async throws {
    let world = try World()

    for _ in 0..<Self.tickCount {
      try await world.tick()
      world.clock.advance(by: Self.tickInterval)
    }

    let kinds = await world.spy.kinds
    let listPanes = kinds.filter { $0 == .listPanes }.count
    let processTable = kinds.filter { $0 == .ps }.count
    let captureBatches = kinds.filter(\.isCaptureBatch).count

    // pane 一覧は tick ごとに1回だけ。worktree 数 (5) には比例しない。
    #expect(listPanes == Self.tickCount)
    // ps は TTL 2.5s なので 2s の tick 2回に1回。pane 数 (10) には比例しない。
    #expect(processTable == 5)
    // 画面は tick ごとに1バッチ。初回だけ pane の登録が増えるぶん余分に起きる。
    #expect(captureBatches <= Self.tickCount + Self.expectedPaneCount - 1)
    #expect(kinds.count <= 80)
  }

  @Test("登録が揃った後の1 tick は list-panes と capture バッチ各1回で済む")
  func steadyTickCostsTwoTmuxLaunches() async throws {
    let world = try World()
    // 登録が揃うまで回す。
    for _ in 0..<2 {
      try await world.tick()
      world.clock.advance(by: Self.tickInterval)
    }

    let before = await world.spy.kinds.count
    try await world.tick()
    let added = await world.spy.kinds.suffix(from: before)

    #expect(added.filter { $0 == .listPanes }.count == 1)
    #expect(added.filter(\.isCaptureBatch).count == 1)
    #expect(added.contains(.captureBatch(paneCount: Self.expectedPaneCount)))
  }

  /// App と同じ配線を、実時計に依存しない形で1 tick ずつ進める入れ物。
  private struct World {
    let clock = ManualTimeSource()
    let spy: ObservationProcessSpy
    let paneSource: TmuxWorktreePaneSource
    let signalSource: TmuxAgentSignalSource
    let worktrees: [WorktreeIdentity]

    init() throws {
      var identities: [WorktreeIdentity] = []
      var lines = ""
      var paneNumber = 0
      for index in 0..<ObservationLaunchBudgetTests.worktreeCount {
        let identity = try #require(
          WorktreeIdentity(rawValue: "/repo/.git/worktrees/budget-\(index)"))
        identities.append(identity)
        for _ in 0..<ObservationLaunchBudgetTests.panesPerWorktree {
          lines += makeListPanesLine(
            session: TmuxSessionName(identity: identity).rawValue,
            paneID: "%\(paneNumber)", panePID: Int32(1_000 + paneNumber))
          paneNumber += 1
        }
      }
      // ユーザー自身の session の pane も混ぜる。`-a` はこれも返す。
      lines += makeListPanesLine(session: "user", paneID: "%99", panePID: 9_999)

      let screens = (0..<paneNumber).reduce(into: [PaneID: [String]]()) {
        $0[PaneID(rawValue: "%\($1)")] = ["screen\n"]
      }
      let spy = ObservationProcessSpy(
        screens: screens, listPanesOutput: lines,
        processTableOutput: (0..<paneNumber)
          .map { "\(1_000 + $0) 1 /opt/tools/claude\n" }.joined())
      let runner = try makeTmuxRunner(socketName: "budget-test", processRunner: spy)
      self.spy = spy
      self.worktrees = identities
      self.paneSource = TmuxWorktreePaneSource(
        runner: runner,
        paneList: TmuxAllSessionPaneListCache(
          runner: runner, timeToLive: TmuxAllSessionPaneListCache.defaultTimeToLive,
          timeSource: clock))
      self.signalSource = TmuxAgentSignalSource(
        processTable: ProcessTableSnapshotCache(
          processRunner: spy, executableURL: URL(fileURLWithPath: "/ps"),
          timeToLive: ProcessTableSnapshotCache.defaultTimeToLive, timeSource: clock),
        screenBatcher: TmuxPaneScreenBatcher(
          runner: runner, timeToLive: TmuxPaneScreenBatcher.defaultTimeToLive,
          timeSource: clock))
    }

    /// worktree ごとの pane 一覧 poll と、pane ごとの signals / liveness を1周ぶん回す。
    /// `liveness` は最悪ケースとして毎 tick 呼ぶ (実際は 5s 周期)。
    func tick() async throws {
      var panes: [PaneSnapshot] = []
      for worktree in worktrees {
        panes.append(contentsOf: try await paneSource.panes(of: worktree))
      }
      #expect(panes.count == ObservationLaunchBudgetTests.expectedPaneCount)
      for pane in panes {
        _ = await signalSource.liveness(for: pane, matchingProcessNames: ["claude"])
        _ = try await signalSource.signals(for: pane, minimumChangedLines: 1)
      }
    }
  }
}
