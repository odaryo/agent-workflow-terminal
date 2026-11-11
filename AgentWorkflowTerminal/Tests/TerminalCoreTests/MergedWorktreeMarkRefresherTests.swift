import TerminalCore
import Testing

/// 周の終わりは、次の周が既定 branch の先端を読んだことで知る (`settle`)。refresher は周の終わりを
/// 外へ知らせないので、「呼ばれなかった」の観測はこの区切りの後で行う。
///
/// - Important: `.timeLimit` は、待ち合わせを取り違えたときにハングで CI の時間を食わないため。
///   個々の待ちは `waitUntil` の上限で打ち切る。
@Suite("Issue #879 マージ済みの印を周ごとに更新する", .timeLimit(.minutes(1)))
struct MergedWorktreeMarkRefresherTests {
  @Test("マージ済みと判定した先端は、既定 branch が進んだ次の周でも判定せず、印を残す")
  func keepsMergedTipAcrossDefaultBranchMoves() async throws {
    let tip = try MarkFixture.oid("1")
    let firstDestination = try MarkFixture.oid("d")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: firstDestination)
    await probe.markMerged(tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await changes.log.last == [topic.identity] })
    await probe.setDefaultTip(try MarkFixture.oid("e"))
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await settle(refresher, targets: [topic], probe: probe))

    #expect(await probe.judgements == [.init(tip: tip, destination: firstDestination)])
    let values = await changes.log.values
    #expect(Array(values.drop(while: { $0 != [topic.identity] })) == [[topic.identity]])
  }

  @Test(
    "マージ済み以外は同じ (先端, 既定先端) の周では判定せず、既定先端が動いた周で判定し直す",
    arguments: [BranchMergeStatus.unmerged, .unknown, .notApplicable])
  func rejudgesNonMergedOnlyWhenDefaultBranchMoves(verdict: BranchMergeStatus) async throws {
    let tip = try MarkFixture.oid("1")
    let firstDestination = try MarkFixture.oid("d")
    let movedDestination = try MarkFixture.oid("e")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: firstDestination)
    await probe.setVerdict(verdict, for: tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await probe.finishedJudgements == 1 })
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await settle(refresher, targets: [topic], probe: probe))
    #expect(await probe.judgements.count == 1)

    await probe.setDefaultTip(movedDestination)
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await probe.judgements.count == 2 })

    #expect(
      await probe.judgements == [
        .init(tip: tip, destination: firstDestination),
        .init(tip: tip, destination: movedDestination),
      ])
    #expect(await changes.log.values.allSatisfy(\.isEmpty))
  }

  @Test("判定の途中で stop したら結果を記録せず、以後の request は何も読まない")
  func stopDiscardsJudgementInFlight() async throws {
    let heldTip = try MarkFixture.oid("1")
    let laterTip = try MarkFixture.oid("2")
    let destination = try MarkFixture.oid("d")
    let held = try MarkFixture.worktree("held", branch: "held")
    let later = try MarkFixture.worktree("later", branch: "later")
    let probe = FakeBranchMergeProbe(
      tips: ["held": heldTip, "later": laterTip], defaultTip: destination)
    await probe.markMerged(heldTip)
    await probe.markMerged(laterTip)
    await probe.hold(heldTip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [held, later], probe: probe))
    try #require(await waitUntil { await probe.judgements.count == 1 })
    await refresher.stop()
    let branchTipReadsAtStop = await probe.branchTipReads
    let defaultReadsAtStop = await probe.defaultBranchTipReads
    await probe.release(heldTip)
    try #require(await waitUntil { await probe.finishedJudgements == 1 })
    await refresher.request(targets: [held, later], projectRootBranch: "main")

    // 止めた後は何も起こらないので、終わりを知らせる区切りが無い。時間で待つのはここだけで、
    // 遅いマシンでは誤った実装を見逃しうるが、正しい実装を落とすことはない。
    try await Task.sleep(for: .milliseconds(300))
    #expect(await probe.judgements == [.init(tip: heldTip, destination: destination)])
    #expect(await changes.log.values.allSatisfy(\.isEmpty))
    #expect(await probe.branchTipReads == branchTipReadsAtStop)
    #expect(await probe.defaultBranchTipReads == defaultReadsAtStop)
  }

  @Test("先端が変わった worktree の印は、新しい先端の判定が返る前に外れる")
  func clearsMarkBeforeJudgingTheNewTip() async throws {
    let mergedTip = try MarkFixture.oid("1")
    let movedTip = try MarkFixture.oid("2")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(
      tips: ["topic": mergedTip], defaultTip: try MarkFixture.oid("d"))
    await probe.markMerged(mergedTip)
    await probe.markMerged(movedTip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await changes.log.last == [topic.identity] })
    await probe.setTip(movedTip, for: "topic")
    await probe.hold(movedTip)
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await probe.judgementCount(of: movedTip) == 1 })

    let clearedWhileJudging = await waitUntil { await changes.log.last == [] }
    await probe.release(movedTip)

    #expect(clearedWhileJudging)
    #expect(await waitUntil { await changes.log.last == [topic.identity] })
  }

  @Test("detached と到達不能の worktree は先端を読まず、先端を読めなかった worktree と同じく印を出さない")
  func skipsWorktreesWithoutReadableTips() async throws {
    let topicTip = try MarkFixture.oid("1")
    let unreachableTip = try MarkFixture.oid("2")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let targets = [
      try MarkFixture.worktree("detached", branch: nil),
      try MarkFixture.worktree("far", branch: "far", isReachable: false),
      try MarkFixture.worktree("gone", branch: "gone"),
      topic,
    ]
    let probe = FakeBranchMergeProbe(
      tips: ["topic": topicTip, "far": unreachableTip], defaultTip: try MarkFixture.oid("d"))
    await probe.markMerged(topicTip)
    await probe.markMerged(unreachableTip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: targets, probe: probe))
    try #require(await waitUntil { await changes.log.last == [topic.identity] })
    try #require(await settle(refresher, targets: targets, probe: probe))

    #expect(Set(await probe.branchTipReads) == ["gone", "topic"])
    #expect(await probe.judgements.map(\.tip) == [topicTip])
    #expect(await changes.log.last == [topic.identity])
  }

  @Test("targets から消えた worktree は印から消える")
  func dropsMarkOfWorktreeLeavingTargets() async throws {
    let firstTip = try MarkFixture.oid("1")
    let secondTip = try MarkFixture.oid("2")
    let first = try MarkFixture.worktree("first", branch: "first")
    let second = try MarkFixture.worktree("second", branch: "second")
    let probe = FakeBranchMergeProbe(
      tips: ["first": firstTip, "second": secondTip], defaultTip: try MarkFixture.oid("d"))
    await probe.markMerged(firstTip)
    await probe.markMerged(secondTip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [first, second], probe: probe))
    try #require(
      await waitUntil { await changes.log.last == [first.identity, second.identity] })
    try #require(await requestCycle(refresher, targets: [second], probe: probe))

    #expect(await waitUntil { await changes.log.last == [second.identity] })
  }

  @Test("周回中に来た複数の要求は、今の周の後に1回だけ、最後の要求で回る")
  func coalescesRequestsArrivingDuringACycle() async throws {
    let runningTip = try MarkFixture.oid("1")
    let probe = FakeBranchMergeProbe(
      tips: [
        "running": runningTip, "skipped": try MarkFixture.oid("2"),
        "latest": try MarkFixture.oid("3"), "fence": try MarkFixture.oid("4"),
      ],
      defaultTip: try MarkFixture.oid("d"))
    await probe.hold(runningTip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    await refresher.request(
      targets: [try MarkFixture.worktree("running", branch: "running")],
      projectRootBranch: "main")
    try #require(await waitUntil { await probe.judgementCount(of: runningTip) == 1 })
    await refresher.request(
      targets: [try MarkFixture.worktree("skipped", branch: "skipped")],
      projectRootBranch: "skipped-root")
    await refresher.request(
      targets: [try MarkFixture.worktree("latest", branch: "latest")],
      projectRootBranch: "latest-root")
    await probe.release(runningTip)
    try #require(await waitUntil { await probe.branchTipReads.contains("latest") })
    await refresher.request(
      targets: [try MarkFixture.worktree("fence", branch: "fence")], projectRootBranch: "main")
    try #require(
      await waitUntil {
        let reads = await probe.branchTipReads
        let defaultReads = await probe.defaultBranchTipReads
        return reads.contains("fence") && defaultReads >= 3
      })

    #expect(await probe.branchTipReads == ["running", "latest", "fence"])
    #expect(await probe.defaultBranchTipQueries == ["main", "latest-root", "main"])
  }

  @Test("既定 branch の先端を決められない周は判定せず印を出さず、決まった周で判定する")
  func skipsJudgementWithoutDefaultBranchTip() async throws {
    let tip = try MarkFixture.oid("1")
    let destination = try MarkFixture.oid("d")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: nil)
    await probe.markMerged(tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await settle(refresher, targets: [topic], probe: probe))
    #expect(await probe.judgements.isEmpty)
    #expect(await changes.log.values.allSatisfy(\.isEmpty))

    await probe.setDefaultTip(destination)
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))

    #expect(await waitUntil { await changes.log.last == [topic.identity] })
    #expect(await probe.judgements == [.init(tip: tip, destination: destination)])
  }

  @Test("同じ周で同じ先端の worktree が2つあれば、判定は1回で両方に印が出る")
  func judgesSharedTipOnce() async throws {
    let tip = try MarkFixture.oid("1")
    let first = try MarkFixture.worktree("first", branch: "first")
    let second = try MarkFixture.worktree("second", branch: "second")
    let probe = FakeBranchMergeProbe(
      tips: ["first": tip, "second": tip], defaultTip: try MarkFixture.oid("d"))
    await probe.markMerged(tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [first, second], probe: probe))
    try #require(
      await waitUntil { await changes.log.last == [first.identity, second.identity] })
    try #require(await settle(refresher, targets: [first, second], probe: probe))

    #expect(await probe.judgements.count == 1)
  }

  @Test(
    "同じ先端の未マージ等の判定は1周に1回だけ行い、両 worktree に記録し、既定先端が動けば判定し直す",
    arguments: [BranchMergeStatus.unmerged, .unknown, .notApplicable])
  func judgesSharedNonMergedTipOncePerDestination(verdict: BranchMergeStatus) async throws {
    let tip = try MarkFixture.oid("1")
    let firstDestination = try MarkFixture.oid("d")
    let movedDestination = try MarkFixture.oid("e")
    let first = try MarkFixture.worktree("first", branch: "first")
    let second = try MarkFixture.worktree("second", branch: "second")
    let targets = [first, second]
    let probe = FakeBranchMergeProbe(
      tips: ["first": tip, "second": tip], defaultTip: firstDestination)
    await probe.setVerdict(verdict, for: tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: targets, probe: probe))
    try #require(await settle(refresher, targets: targets, probe: probe))
    #expect(await probe.judgements.count == 1)

    try #require(await requestCycle(refresher, targets: targets, probe: probe))
    try #require(await settle(refresher, targets: targets, probe: probe))
    #expect(await probe.judgements.count == 1)

    let countBeforeMove = await probe.judgements.count
    await probe.setDefaultTip(movedDestination)
    try #require(await requestCycle(refresher, targets: targets, probe: probe))
    try #require(await settle(refresher, targets: targets, probe: probe))

    #expect(await probe.judgements.count - countBeforeMove == 1)
    #expect(await probe.judgements.last?.destination == movedDestination)
  }

  @Test(
    "同じ先端が ancestor でも first-parent の列の上または読めない場合は両判定を1回だけ行い、印を出さない",
    arguments: [true, nil] as [Bool?])
  func judgesSharedFirstParentTipOnce(answer: Bool?) async throws {
    let tip = try MarkFixture.oid("1")
    let first = try MarkFixture.worktree("first", branch: "first")
    let second = try MarkFixture.worktree("second", branch: "second")
    let targets = [first, second]
    let probe = FakeBranchMergeProbe(
      tips: ["first": tip, "second": tip], defaultTip: try MarkFixture.oid("d"))
    await probe.markMerged(tip)
    await probe.setFirstParentAnswer(answer, for: tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: targets, probe: probe))
    try #require(await settle(refresher, targets: targets, probe: probe))

    #expect(await probe.judgements.count == 1)
    #expect(await probe.firstParentQueries.count == 1)
    #expect(await changes.log.values.allSatisfy(\.isEmpty))
  }

  @Test("2つの refresher が queue を共有すると、判定は同時に2つ走らない")
  func sharedQueueSerializesJudgementsAcrossRefreshers() async throws {
    let gauge = JudgementConcurrencyGauge()
    let queue = BranchMergeJudgementQueue()
    let (firstProbe, firstTargets) = try Self.busyProject("a", gauge: gauge)
    let (secondProbe, secondTargets) = try Self.busyProject("b", gauge: gauge)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let firstRefresher = MergedWorktreeMarkRefresher(
      probe: firstProbe, queue: queue, onChange: changes.onChange)
    let secondRefresher = MergedWorktreeMarkRefresher(
      probe: secondProbe, queue: queue, onChange: changes.onChange)

    await firstRefresher.request(targets: firstTargets, projectRootBranch: "main")
    await secondRefresher.request(targets: secondTargets, projectRootBranch: "main")
    try #require(
      await waitUntil(timeout: .seconds(10)) {
        let first = await firstProbe.finishedJudgements
        let second = await secondProbe.finishedJudgements
        return first == firstTargets.count && second == secondTargets.count
      })

    #expect(await gauge.maximum == 1)
  }

  /// 上のテストが「同時に走らない」を主張できるのは、共有の queue を通さずに同じ probe を並べれば
  /// gauge が重なりを数えるからである。その前提をここで assertion にする。
  @Test("対照: queue を通さずに判定を並べると、gauge は重なりを数える")
  func gaugeObservesOverlapWithoutQueue() async throws {
    let gauge = JudgementConcurrencyGauge()
    let (firstProbe, _) = try Self.busyProject("a", gauge: gauge)
    let (secondProbe, _) = try Self.busyProject("b", gauge: gauge)
    let destination = try MarkFixture.oid("d")
    let firstTip = try MarkFixture.oid("1")
    let secondTip = try MarkFixture.oid("2")

    async let first = firstProbe.mergeStatus(tip: firstTip, destination: destination)
    async let second = secondProbe.mergeStatus(tip: secondTip, destination: destination)
    _ = await (first, second)

    #expect(await gauge.maximum == 2)
  }

  @Test("onChange は同じ値で続けて呼ばない")
  func neverRepeatsTheSameMarksConsecutively() async throws {
    let mergedTip = try MarkFixture.oid("1")
    let unmergedTip = try MarkFixture.oid("2")
    let unknownTip = try MarkFixture.oid("3")
    let targets = [
      try MarkFixture.worktree("merged", branch: "merged"),
      try MarkFixture.worktree("unmerged", branch: "unmerged"),
      try MarkFixture.worktree("unknown", branch: "unknown"),
    ]
    let probe = FakeBranchMergeProbe(
      tips: ["merged": mergedTip, "unmerged": unmergedTip, "unknown": unknownTip],
      defaultTip: try MarkFixture.oid("d"))
    await probe.markMerged(mergedTip)
    await probe.setVerdict(.unknown, for: unknownTip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: targets, probe: probe))
    try #require(await waitUntil { await probe.finishedJudgements == 3 })
    try #require(await requestCycle(refresher, targets: targets, probe: probe))
    try #require(await settle(refresher, targets: targets, probe: probe))

    let values = await changes.log.values
    #expect(values.last == [targets[0].identity])
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 != $1 })
  }

  /// 判定ごとに少し時間のかかる worktree を3つ持つ Project。判定が重なる機会を作るため。
  private static func busyProject(
    _ prefix: String, gauge: JudgementConcurrencyGauge
  ) throws -> (FakeBranchMergeProbe, [DetectedWorktree]) {
    let names = (1...3).map { "\(prefix)\($0)" }
    let digits: [Character] = prefix == "a" ? ["1", "2", "3"] : ["4", "5", "6"]
    var tips: [String: CommitObjectID] = [:]
    for (name, digit) in zip(names, digits) {
      tips[name] = try MarkFixture.oid(digit)
    }
    let probe = FakeBranchMergeProbe(
      tips: tips, defaultTip: try MarkFixture.oid("d"), gauge: gauge,
      judgementDuration: .milliseconds(30))
    return (probe, try names.map { try MarkFixture.worktree($0, branch: $0) })
  }
}
