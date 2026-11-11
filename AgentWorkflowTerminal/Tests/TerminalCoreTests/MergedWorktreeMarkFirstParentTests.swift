import TerminalCore
import Testing

/// 作っただけの branch は既定 branch の祖先なので ancestor の根拠でマージ済みになる。先端が既定
/// branch の first-parent の列の上にあれば、取り込まれた自分の作業が無いとみなして印を出さない
/// (Issue #879 のレビュー round 1、git 2.54.0 で計測)。
@Suite("Issue #879 first-parent の列の上の先端には印を出さない", .timeLimit(.minutes(1)))
struct MergedWorktreeMarkFirstParentTests {
  /// `true` は `.unmerged`、`nil` は `.unknown` として記録する。どちらも同じ組では判定し直さない
  /// ので、公開面からは区別できない。
  @Test(
    "ancestor で merged でも first-parent の列の上 (または読めない) なら印を出さず、同じ組では判定し直さない",
    arguments: [true, nil] as [Bool?])
  func suppressesMarkOnFirstParentChain(answer: Bool?) async throws {
    let tip = try MarkFixture.oid("1")
    let firstDestination = try MarkFixture.oid("d")
    let movedDestination = try MarkFixture.oid("e")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: firstDestination)
    await probe.markMerged(tip)
    await probe.setFirstParentAnswer(answer, for: tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await probe.firstParentQueries.count == 1 })
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await settle(refresher, targets: [topic], probe: probe))
    #expect(await probe.judgements == [.init(tip: tip, destination: firstDestination)])
    #expect(await probe.firstParentQueries == [.init(tip: tip, destination: firstDestination)])

    await probe.setDefaultTip(movedDestination)
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await probe.firstParentQueries.count == 2 })

    let expected: [FakeBranchMergeProbe.Judgement] = [
      .init(tip: tip, destination: firstDestination),
      .init(tip: tip, destination: movedDestination),
    ]
    #expect(await probe.judgements == expected)
    #expect(await probe.firstParentQueries == expected)
    #expect(await changes.log.values.allSatisfy(\.isEmpty))
  }

  @Test("ancestor で merged で first-parent の列の上に無ければ印を出す")
  func marksAncestorMergeOffTheFirstParentChain() async throws {
    let tip = try MarkFixture.oid("1")
    let destination = try MarkFixture.oid("d")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: destination)
    await probe.markMerged(tip)
    await probe.setFirstParentAnswer(false, for: tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await changes.log.last == [topic.identity] })
    try #require(await settle(refresher, targets: [topic], probe: probe))

    #expect(await probe.firstParentQueries == [.init(tip: tip, destination: destination)])
    #expect(await changes.log.last == [topic.identity])
  }

  @Test("squash の根拠で merged なら first-parent を問わずに印を出す")
  func marksSquashMergeWithoutAskingFirstParent() async throws {
    let tip = try MarkFixture.oid("1")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: try MarkFixture.oid("d"))
    await probe.setVerdict(.merged(.squash, tip: tip), for: tip)
    await probe.setFirstParentAnswer(true, for: tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await changes.log.last == [topic.identity] })
    try #require(await settle(refresher, targets: [topic], probe: probe))

    #expect(await probe.firstParentQueries.isEmpty)
    #expect(await changes.log.last == [topic.identity])
  }

  @Test(
    "マージ済み以外の答えでは first-parent を問わない",
    arguments: [BranchMergeStatus.unmerged, .unknown, .notApplicable])
  func neverAsksFirstParentForNonMergedVerdicts(verdict: BranchMergeStatus) async throws {
    let tip = try MarkFixture.oid("1")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: try MarkFixture.oid("d"))
    await probe.setVerdict(verdict, for: tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await probe.finishedJudgements == 1 })
    try #require(await settle(refresher, targets: [topic], probe: probe))

    #expect(await probe.firstParentQueries.isEmpty)
  }

  /// first-parent の問い合わせを重い判定と別に列へ並べる (または列の外で撃つ) と、その間に別の
  /// Project の重い判定が始まる。
  @Test("first-parent の問い合わせは重い判定と同じ1件として列を占め、その間に他の判定は始まらない")
  func firstParentQueryHoldsTheSharedQueue() async throws {
    let heldTip = try MarkFixture.oid("1")
    let otherTip = try MarkFixture.oid("2")
    let queue = BranchMergeJudgementQueue()
    let heldProbe = FakeBranchMergeProbe(
      tips: ["held": heldTip], defaultTip: try MarkFixture.oid("d"))
    await heldProbe.markMerged(heldTip)
    await heldProbe.holdFirstParent(heldTip)
    let otherProbe = FakeBranchMergeProbe(
      tips: ["other": otherTip], defaultTip: try MarkFixture.oid("e"))
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let heldRefresher = MergedWorktreeMarkRefresher(
      probe: heldProbe, queue: queue, onChange: changes.onChange)
    let otherRefresher = MergedWorktreeMarkRefresher(
      probe: otherProbe, queue: queue, onChange: changes.onChange)

    await heldRefresher.request(
      targets: [try MarkFixture.worktree("held", branch: "held")], projectRootBranch: "main")
    try #require(await waitUntil { await heldProbe.firstParentQueries.count == 1 })
    await otherRefresher.request(
      targets: [try MarkFixture.worktree("other", branch: "other")], projectRootBranch: "main")
    // 正しい実装では待ち切るまで始まらないので、ここは時間で待つ。遅いマシンでは誤った実装を
    // 見逃しうるが、正しい実装を落とすことはない。
    let startedWhileHeld = await waitUntil(timeout: .milliseconds(300)) {
      !(await otherProbe.judgements.isEmpty)
    }
    await heldProbe.releaseFirstParent(heldTip)

    #expect(!startedWhileHeld)
    #expect(await waitUntil { await otherProbe.judgements.count == 1 })
  }

  /// 要求 2 (m3) の refresher 側。先端を1周読めなかっただけでマージ済みの記憶を失うと、
  /// 判定し直しになる。
  @Test("先端を1周読めなかったマージ済みの worktree は、読めた周で判定し直さずに印が戻る")
  func restoresMarkWithoutRejudgingAfterUnreadableCycle() async throws {
    let tip = try MarkFixture.oid("1")
    let topic = try MarkFixture.worktree("topic", branch: "topic")
    let probe = FakeBranchMergeProbe(tips: ["topic": tip], defaultTip: try MarkFixture.oid("d"))
    await probe.markMerged(tip)
    let changes = MarkChangeRecorder()
    defer { changes.finish() }
    let refresher = MergedWorktreeMarkRefresher(
      probe: probe, queue: BranchMergeJudgementQueue(), onChange: changes.onChange)

    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await changes.log.last == [topic.identity] })
    await probe.setTip(nil, for: "topic")
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await changes.log.last == [] })
    await probe.setTip(tip, for: "topic")
    try #require(await requestCycle(refresher, targets: [topic], probe: probe))
    try #require(await waitUntil { await changes.log.last == [topic.identity] })
    try #require(await settle(refresher, targets: [topic], probe: probe))

    #expect(await probe.judgements.count == 1)
  }
}
