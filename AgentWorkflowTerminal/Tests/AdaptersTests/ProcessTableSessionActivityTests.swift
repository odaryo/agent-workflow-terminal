import TerminalCore
import Testing

@testable import Adapters

@Suite("pane_pid のプロセス木による session 活動判定 (設計書 §3.1)")
struct ProcessTableSessionActivityTests {
  @Test("生きている pane の活動状態を優先順位どおり集約する", arguments: activityCases)
  func classifiesSession(testCase: SessionActivityCase) {
    let snapshot = ProcessTableSnapshot.parse(testCase.processTable)

    #expect(snapshot.sessionActivity(of: testCase.panes) == testCase.expected)
  }

  @Test(
    "既存の shell 集合と login shell は子が無ければ shellOnly",
    arguments: ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu"])
  func recognizesShellRoots(command: String) {
    for name in [command, "-" + command] {
      let snapshot = ProcessTableSnapshot.parse("100 1 /bin/\(name)\n")

      #expect(snapshot.sessionActivity(of: [(pid: 100, isDead: false)]) == .shellOnly)
    }
  }
}

struct SessionActivityCase: Sendable, CustomTestStringConvertible {
  let testDescription: String
  let processTable: String
  let panes: [(pid: Int32, isDead: Bool)]
  let expected: TerminalSessionActivity
}

private let activityCases: [SessionActivityCase] = [
  SessionActivityCase(
    testDescription: "pane 無し → shellOnly", processTable: "100 1 /bin/sleep\n",
    panes: [], expected: .shellOnly),
  SessionActivityCase(
    testDescription: "死んだ pane のみ → shellOnly", processTable: "100 1 /bin/sleep\n",
    panes: [(100, true), (200, true)], expected: .shellOnly),
  SessionActivityCase(
    testDescription: "zsh・子無し → shellOnly", processTable: "100 1 /bin/zsh\n",
    panes: [(100, false)], expected: .shellOnly),
  SessionActivityCase(
    testDescription: "login zsh・子無し → shellOnly", processTable: "100 1 -zsh\n",
    panes: [(100, false)], expected: .shellOnly),
  SessionActivityCase(
    testDescription: "bash → bash → sleep → running",
    processTable: "100 1 /bin/bash\n101 100 /bin/bash\n102 101 /bin/sleep\n",
    panes: [(100, false)], expected: .running),
  SessionActivityCase(
    testDescription: "sh → sleep → running",
    processTable: "100 1 /bin/sh\n101 100 /bin/sleep\n",
    panes: [(100, false)], expected: .running),
  SessionActivityCase(
    testDescription: "根が sleep → running", processTable: "100 1 /bin/sleep\n",
    panes: [(100, false)], expected: .running),
  SessionActivityCase(
    testDescription: "根が表に無い → undetermined", processTable: "200 1 /bin/zsh\n",
    panes: [(100, false)], expected: .undetermined),
  SessionActivityCase(
    testDescription: "shellOnly + running → running",
    processTable: "100 1 /bin/zsh\n200 1 /bin/sleep\n",
    panes: [(100, false), (200, false)], expected: .running),
  SessionActivityCase(
    testDescription: "shellOnly + undetermined → undetermined", processTable: "100 1 /bin/zsh\n",
    panes: [(100, false), (200, false)], expected: .undetermined),
  SessionActivityCase(
    testDescription: "死んだ sleep + 生きた zsh → shellOnly",
    processTable: "100 1 /bin/sleep\n200 1 /bin/zsh\n",
    panes: [(100, true), (200, false)], expected: .shellOnly),
  SessionActivityCase(
    testDescription: "zsh → zsh (サブシェル) → running",
    processTable: "100 1 /bin/zsh\n101 100 /bin/zsh\n",
    panes: [(100, false)], expected: .running),
  SessionActivityCase(
    testDescription: "undetermined + running → running", processTable: "200 1 /bin/sleep\n",
    panes: [(100, false), (200, false)], expected: .running),
  SessionActivityCase(
    testDescription: "running + undetermined → running", processTable: "100 1 /bin/sleep\n",
    panes: [(100, false), (200, false)], expected: .running),
  SessionActivityCase(
    testDescription: "shellOnly + shellOnly → shellOnly",
    processTable: "100 1 /bin/zsh\n200 1 /bin/fish\n",
    panes: [(100, false), (200, false)], expected: .shellOnly),
  SessionActivityCase(
    testDescription: "無関係な木の sleep は無視 → shellOnly",
    processTable: "100 1 /bin/zsh\n200 1 /bin/bash\n201 200 /bin/sleep\n",
    panes: [(100, false)], expected: .shellOnly),
]
