import TerminalCore
import Testing

@testable import Adapters

@Suite("§12.4.2 再選択の liveness と ps の鮮度")
struct TmuxAgentSignalSourceReselectionTests {
  @Test("q1: 前景が変わった直後は TTL 内でも新しい ps で生存確認する")
  func foregroundChangeRefreshesLiveness() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let initial = pane(command: "zsh")
    #expect(await source.liveness(for: initial, matchingProcessNames: ["claude"]) == .absent)
    #expect(await spy.count(of: .ps) == 1)

    await spy.setProcessTableOutput("70 1 /bin/bash\n71 70 claude\n")
    clock.advance(by: .seconds(1))
    let changed = pane(command: "bash")

    #expect(await source.liveness(for: changed, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 2)
  }

  @Test("q2: 再選択で続けて別の名前の集合を引いても ps の起動は増えない")
  func secondNameSetReusesReselectionSnapshot() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    _ = await source.liveness(for: pane(command: "zsh"), matchingProcessNames: ["claude"])
    await spy.setProcessTableOutput("70 1 /bin/bash\n71 70 claude\n")
    clock.advance(by: .seconds(1))
    let changed = pane(command: "bash")
    _ = await source.liveness(for: changed, matchingProcessNames: ["claude"])
    let launchesAfterFirstNameSet = await spy.count(of: .ps)

    #expect(await source.liveness(for: changed, matchingProcessNames: ["codex"]) == .absent)
    #expect(await spy.count(of: .ps) == launchesAfterFirstNameSet)
  }

  @Test("q3: claude から codex にすぐ入れ替わった最初の画面は前の画面と比較しない")
  func immediateAgentReplacementStartsNewScreenHistory() async throws {
    let spy = ObservationProcessSpy(
      screens: [PaneID(rawValue: "%7"): ["screen A\n", "screen B\n"]],
      processTableOutput: "70 1 /bin/zsh\n71 70 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let initial = pane(command: "claude")
    #expect(await source.liveness(for: initial, matchingProcessNames: ["claude"]) == .alive)
    let first = try await source.signals(for: initial, minimumChangedLines: 1)
    #expect(first.screenText == "screen A\n")
    #expect(first.secondsSinceScreenChange == nil)

    await spy.setProcessTableOutput("70 1 /bin/zsh\n72 70 codex\n")
    clock.advance(by: .seconds(1))
    let changed = pane(command: "codex")
    #expect(await source.liveness(for: changed, matchingProcessNames: ["claude"]) == .absent)
    #expect(await source.liveness(for: changed, matchingProcessNames: ["codex"]) == .alive)
    let second = try await source.signals(for: changed, minimumChangedLines: 1)

    #expect(second.screenText == "screen B\n")
    #expect(second.secondsSinceScreenChange == nil)
    #expect(await spy.count(of: .ps) == 2)
  }

  @Test("q4: pane が変わらなければ TTL 内の ps を使う")
  func unchangedPaneReusesSnapshotWithinTimeToLive() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n71 70 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let unchanged = pane(command: "zsh")
    #expect(await source.liveness(for: unchanged, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 1)
    clock.advance(by: .seconds(1))

    #expect(await source.liveness(for: unchanged, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 1)
  }

  @Test("s5: 初めての pane でも listedAt より前に読み始めた ps は使わない")
  func firstLivenessRejectsProcessTableOlderThanListedAt() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n80 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let start = clock.now
    let other = pane(id: "%8", processID: 80, command: "zsh")
    #expect(await source.liveness(for: other, matchingProcessNames: ["claude"]) == .absent)
    #expect(await spy.count(of: .ps) == 1)

    await spy.setProcessTableOutput("70 1 /bin/zsh\n71 70 claude\n80 1 /bin/zsh\n")
    clock.advance(by: .seconds(1))
    let created = pane(command: "claude", listedAt: start.advanced(by: .milliseconds(500)))

    #expect(await source.liveness(for: created, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 2)
  }

  @Test("s6: 同じ listedAt の初めての pane が続いても ps は1回で足りる")
  func panesFromOneListingShareOneProcessTable() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n80 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let start = clock.now
    let other = pane(id: "%8", processID: 80, command: "zsh")
    _ = await source.liveness(for: other, matchingProcessNames: ["claude"])

    await spy.setProcessTableOutput(
      "70 1 /bin/zsh\n71 70 claude\n80 1 /bin/zsh\n90 1 /bin/zsh\n91 90 claude\n")
    clock.advance(by: .seconds(1))
    let listedAt = start.advanced(by: .milliseconds(500))
    let first = pane(command: "claude", listedAt: listedAt)
    let second = pane(id: "%9", processID: 90, command: "claude", listedAt: listedAt)

    #expect(await source.liveness(for: first, matchingProcessNames: ["claude"]) == .alive)
    #expect(await source.liveness(for: second, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 2)
  }

  @Test("s7: listedAt が最初の ps より古い定常の観測では TTL 内の ps を使う")
  func steadyObservationWithOldListedAtReusesProcessTable() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n71 70 claude\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let steady = pane(command: "claude", listedAt: clock.now.advanced(by: .milliseconds(-500)))
    #expect(await source.liveness(for: steady, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 1)
    clock.advance(by: .seconds(1))

    #expect(await source.liveness(for: steady, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 1)
  }

  @Test("p8: listedAt を持たない初めての pane は TTL 内の ps を使う")
  func firstLivenessWithoutListedAtReusesProcessTable() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n80 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let other = pane(id: "%8", processID: 80, command: "zsh")
    #expect(await source.liveness(for: other, matchingProcessNames: ["claude"]) == .absent)
    #expect(await spy.count(of: .ps) == 1)
    clock.advance(by: .seconds(1))

    let first = pane(command: "zsh")
    #expect(await source.liveness(for: first, matchingProcessNames: ["claude"]) == .absent)
    #expect(await spy.count(of: .ps) == 1)
  }

  @Test(
    "p11: 消えた pane と同じ ID がまた来たら、初めての pane として listedAt 以後の ps で確かめる",
    arguments: PaneDisappearance.allCases)
  func reappearedPaneIsTreatedAsFirstLiveness(disappearance: PaneDisappearance) async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n80 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let observed = pane(command: "zsh")
    #expect(await source.liveness(for: observed, matchingProcessNames: ["claude"]) == .absent)

    switch disappearance {
    case .paneNotFound:
      await spy.setMissing([observed.id])
      await #expect(throws: TmuxAgentSignalSourceError.paneNotFound(observed.id)) {
        try await source.signals(for: observed, minimumChangedLines: 1)
      }
      await spy.setMissing([])
    case .dead:
      let dead = PaneSnapshot(
        id: observed.id, processID: observed.processID, tty: "", currentCommand: "zsh",
        currentPath: "", title: "", termination: .exited(status: 0))
      #expect(await source.liveness(for: dead, matchingProcessNames: ["claude"]) == .absent)
    case .forgetExpired:
      await source.forget(observed)
      clock.advance(by: PaneNotificationPlanner.paneHandoffGrace + .seconds(1))
      // 期限切れの後始末は、別の pane の呼び出しの入口で走る。
      let other = pane(id: "%8", processID: 80, command: "zsh")
      _ = await source.liveness(for: other, matchingProcessNames: ["claude"])
    }
    let launchesBeforeReappearance = await spy.count(of: .ps)
    await spy.setProcessTableOutput("70 1 /bin/zsh\n71 70 claude\n80 1 /bin/zsh\n")
    clock.advance(by: .seconds(1))
    let reappeared = pane(command: "zsh", listedAt: clock.now.advanced(by: .milliseconds(-500)))

    #expect(await source.liveness(for: reappeared, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == launchesBeforeReappearance + 1)
  }

  @Test("y5: 同じ listedAt の一覧で複数の pane の前景が同時に変わっても ps は1回で足りる")
  func foregroundChangesFromOneListingShareOneProcessTable() async throws {
    let spy = ObservationProcessSpy(processTableOutput: "70 1 /bin/zsh\n80 1 /bin/zsh\n")
    let clock = ManualTimeSource()
    let source = try makeSource(spy: spy, clock: clock)
    let start = clock.now
    _ = await source.liveness(for: pane(command: "zsh"), matchingProcessNames: ["claude"])
    _ = await source.liveness(
      for: pane(id: "%8", processID: 80, command: "zsh"), matchingProcessNames: ["claude"])
    #expect(await spy.count(of: .ps) == 1)

    await spy.setProcessTableOutput(
      "70 1 /bin/bash\n71 70 claude\n80 1 /bin/bash\n81 80 claude\n")
    clock.advance(by: .seconds(1))
    let listedAt = start.advanced(by: .milliseconds(500))
    let first = pane(command: "bash", listedAt: listedAt)
    let second = pane(id: "%8", processID: 80, command: "bash", listedAt: listedAt)

    #expect(await source.liveness(for: first, matchingProcessNames: ["claude"]) == .alive)
    // 2つ目の呼び出しは1つ目より後に届く。呼ばれた時刻を下限にすると、ここで ps が走る。
    clock.advance(by: .milliseconds(100))
    #expect(await source.liveness(for: second, matchingProcessNames: ["claude"]) == .alive)
    #expect(await spy.count(of: .ps) == 2)
  }

  private func pane(
    id: String = "%7", processID: Int32 = 70, command: String,
    listedAt: ContinuousClock.Instant? = nil
  ) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: id), processID: processID, tty: "", currentCommand: command,
      currentPath: "", title: "", termination: nil, listedAt: listedAt)
  }
}

enum PaneDisappearance: CaseIterable, Sendable {
  case paneNotFound
  case dead
  case forgetExpired
}
