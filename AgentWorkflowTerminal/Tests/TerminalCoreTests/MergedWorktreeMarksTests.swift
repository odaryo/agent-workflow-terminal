import TerminalCore
import Testing

/// 判定を繰り返さない条件は、マージ済みとそれ以外で違う (Issue #879 のユーザー決定 2026-11-11)。
/// マージ済みは先端だけで覚え、既定 branch が進んでも使い回す。それ以外は既定 branch が動けば
/// 判定し直す。
@Suite("Issue #879 マージ済みの印の台帳")
struct MergedWorktreeMarksTests {
  @Test("マージ済みと記録した先端は、既定 branch の先端が変わっても判定を求めない")
  func mergedTipNeedsNoJudgementForAnyDestination() throws {
    let topic = try MarkFixture.identity("topic")
    let tip = try MarkFixture.oid("1")
    var marks = MergedWorktreeMarks()

    marks.observeTips([topic: tip])
    #expect(marks.needsJudgement(topic, tip: tip, destination: try MarkFixture.oid("d")))
    marks.record(
      .merged(.ancestor, tip: tip), for: topic, tip: tip, destination: try MarkFixture.oid("d"))

    #expect(marks.markedWorktrees == [topic])
    #expect(!marks.needsJudgement(topic, tip: tip, destination: try MarkFixture.oid("e")))
    #expect(!marks.needsJudgement(topic, tip: tip, destination: nil))
  }

  @Test(
    "マージ済み以外は同じ (先端, 既定先端) では判定を求めず、既定先端が変われば求める",
    arguments: [BranchMergeStatus.unmerged, .unknown, .notApplicable])
  func nonMergedVerdictBlocksOnlyTheSamePair(verdict: BranchMergeStatus) throws {
    let topic = try MarkFixture.identity("topic")
    let tip = try MarkFixture.oid("1")
    let destination = try MarkFixture.oid("d")
    var marks = MergedWorktreeMarks()

    marks.observeTips([topic: tip])
    marks.record(verdict, for: topic, tip: tip, destination: destination)

    #expect(!marks.needsJudgement(topic, tip: tip, destination: destination))
    #expect(marks.needsJudgement(topic, tip: tip, destination: try MarkFixture.oid("e")))
    #expect(marks.markedWorktrees.isEmpty)
  }

  @Test("既定 branch を決められなかった回の記録は、既定先端が決まれば判定を求める")
  func unknownWithoutDestinationYieldsToResolvedDestination() throws {
    let topic = try MarkFixture.identity("topic")
    let tip = try MarkFixture.oid("1")
    var marks = MergedWorktreeMarks()

    marks.observeTips([topic: tip])
    marks.record(.unknown, for: topic, tip: tip, destination: nil)

    #expect(!marks.needsJudgement(topic, tip: tip, destination: nil))
    #expect(marks.needsJudgement(topic, tip: tip, destination: try MarkFixture.oid("d")))
  }

  @Test("マージ済みの先端は worktree をまたいで効く")
  func mergedTipAppliesToEveryWorktreeAtThatTip() throws {
    let first = try MarkFixture.identity("first")
    let second = try MarkFixture.identity("second")
    let tip = try MarkFixture.oid("1")
    let destination = try MarkFixture.oid("d")
    var marks = MergedWorktreeMarks()

    marks.observeTips([first: tip, second: tip])
    marks.record(.merged(.squash, tip: tip), for: first, tip: tip, destination: destination)

    #expect(marks.markedWorktrees == [first, second])
    #expect(!marks.needsJudgement(second, tip: tip, destination: destination))
  }

  @Test("先端が変わった worktree は印を外し、新しい先端の判定を求める")
  func movedTipClearsTheMark() throws {
    let topic = try MarkFixture.identity("topic")
    let merged = try MarkFixture.oid("1")
    let moved = try MarkFixture.oid("2")
    let destination = try MarkFixture.oid("d")
    var marks = MergedWorktreeMarks()

    marks.observeTips([topic: merged])
    marks.record(.merged(.ancestor, tip: merged), for: topic, tip: merged, destination: destination)
    #expect(marks.markedWorktrees == [topic])

    marks.observeTips([topic: moved])

    #expect(marks.markedWorktrees.isEmpty)
    #expect(marks.needsJudgement(topic, tip: moved, destination: destination))
  }

  @Test("tips に現れなかった worktree は印から消える")
  func missingWorktreeLosesItsMark() throws {
    let first = try MarkFixture.identity("first")
    let second = try MarkFixture.identity("second")
    let firstTip = try MarkFixture.oid("1")
    let secondTip = try MarkFixture.oid("2")
    let destination = try MarkFixture.oid("d")
    var marks = MergedWorktreeMarks()

    marks.observeTips([first: firstTip, second: secondTip])
    marks.record(
      .merged(.ancestor, tip: firstTip), for: first, tip: firstTip, destination: destination)
    marks.record(
      .merged(.ancestor, tip: secondTip), for: second, tip: secondTip, destination: destination)
    #expect(marks.markedWorktrees == [first, second])

    marks.observeTips([second: secondTip])

    #expect(marks.markedWorktrees == [second])
  }

  @Test("tips に現れなくなったマージ済みの先端は忘れ、再び現れたら判定を求める")
  func forgetsMergedTipsThatNoLongerAppear() throws {
    let topic = try MarkFixture.identity("topic")
    let other = try MarkFixture.identity("other")
    let tip = try MarkFixture.oid("1")
    let destination = try MarkFixture.oid("d")
    var marks = MergedWorktreeMarks()

    marks.observeTips([topic: tip])
    marks.record(.merged(.ancestor, tip: tip), for: topic, tip: tip, destination: destination)
    #expect(marks.markedWorktrees == [topic])

    marks.observeTips([other: try MarkFixture.oid("2")])
    marks.observeTips([topic: tip])

    #expect(marks.markedWorktrees.isEmpty)
    #expect(marks.needsJudgement(topic, tip: tip, destination: destination))
  }

  @Test("tips に現れなかった worktree の判定済みの組も忘れる")
  func forgetsJudgedPairOfMissingWorktree() throws {
    let topic = try MarkFixture.identity("topic")
    let tip = try MarkFixture.oid("1")
    let destination = try MarkFixture.oid("d")
    var marks = MergedWorktreeMarks()

    marks.observeTips([topic: tip])
    marks.record(.unmerged, for: topic, tip: tip, destination: destination)
    #expect(!marks.needsJudgement(topic, tip: tip, destination: destination))

    marks.observeTips([:])
    marks.observeTips([topic: tip])

    #expect(marks.needsJudgement(topic, tip: tip, destination: destination))
  }
}
