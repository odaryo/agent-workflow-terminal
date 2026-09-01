import Foundation
import TerminalCore
import Testing

/// このファイルは docs/coding-guidelines.md §3.1 から TDD のリファレンス実装として
/// 参照されている。書き方を変えるときは同節も直す。
@Suite("worktree代表状態の解決 (設計書 §12.2 / §12.3)")
struct WorktreeRepresentativeStateTests {

  // MARK: - Helpers

  /// `Date()` を使わず固定値にしているのは、実行時刻に依存させないため。
  /// 各 pane の時刻はここからの相対秒でのみ差をつける。
  private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  private func pane(
    _ id: String,
    _ state: AgentState,
    at offset: TimeInterval = 0
  ) -> PaneAgentState {
    PaneAgentState(
      id: PaneID(rawValue: id),
      state: state,
      lastUpdatedAt: Self.epoch.addingTimeInterval(offset)
    )
  }

  // MARK: - AgentState → WorktreeStateCategory の対応 (§12.2)

  @Test(
    "Question / Permission / Error は Needs Attention として同列に扱う",
    arguments: [AgentState.question, .permission, .error]
  )
  func needsAttentionMapping(state: AgentState) {
    #expect(state.worktreeCategory == .needsAttention)
  }

  @Test("Agent完了は Needs Attention ではなく Ready for Review に分類する")
  func completedMapsToReadyForReview() {
    #expect(AgentState.completed.worktreeCategory == .readyForReview)
    #expect(AgentState.completed.worktreeCategory != .needsAttention)
  }

  @Test("Working / Idle はそれぞれ同名の大分類へ対応する")
  func workingAndIdleMapping() {
    #expect(AgentState.working.worktreeCategory == .working)
    #expect(AgentState.idle.worktreeCategory == .idle)
  }

  @Test("Unknown は Working にも Idle にも丸めない (§12.3)")
  func unknownIsNeverRounded() {
    let category = AgentState.unknown.worktreeCategory
    #expect(category == .unknown)
    #expect(category != .working)
    #expect(category != .idle)
  }

  // MARK: - 大分類の優先順位 (§12.2)

  @Test("優先順位は Needs Attention > Ready for Review > Working > Idle")
  func categoryPriorityOrder() {
    #expect(WorktreeStateCategory.needsAttention > .readyForReview)
    #expect(WorktreeStateCategory.readyForReview > .working)
    #expect(WorktreeStateCategory.working > .idle)
  }

  @Test("Unknown は Working にも Idle にも一致せず、両者の間に位置する")
  func unknownSitsBetweenWorkingAndIdle() {
    #expect(WorktreeStateCategory.working > .unknown)
    #expect(WorktreeStateCategory.unknown > .idle)
  }

  // MARK: - 代表状態の解決

  @Test("pane が無い worktree には代表状態が存在しない")
  func noPanesYieldsNoState() {
    #expect(resolveWorktreeRepresentativeState(panes: []) == nil)
  }

  @Test("pane が1つならその状態がそのまま代表になる")
  func singlePaneIsRepresentative() {
    let resolved = resolveWorktreeRepresentativeState(panes: [pane("%0", .working)])
    #expect(resolved?.state == .working)
    #expect(resolved?.category == .working)
    #expect(resolved?.paneID == PaneID(rawValue: "%0"))
  }

  @Test("複数 pane では最重要の大分類が1つだけ代表になる")
  func highestCategoryWins() {
    let resolved = resolveWorktreeRepresentativeState(
      panes: [
        pane("%0", .idle),
        pane("%1", .working),
        pane("%2", .completed),
      ]
    )
    #expect(resolved?.category == .readyForReview)
    #expect(resolved?.paneID == PaneID(rawValue: "%2"))
  }

  @Test("Needs Attention は Ready for Review より優先される")
  func needsAttentionBeatsReadyForReview() {
    let resolved = resolveWorktreeRepresentativeState(
      panes: [
        pane("%0", .completed, at: 100),
        pane("%1", .question, at: 0),
      ]
    )
    #expect(resolved?.state == .question)
    #expect(resolved?.paneID == PaneID(rawValue: "%1"))
  }

  @Test("Needs Attention 内では最終更新が新しい pane を代表とする (§12.2)")
  func needsAttentionTiebreaksByRecency() {
    let resolved = resolveWorktreeRepresentativeState(
      panes: [
        pane("%0", .question, at: 10),
        pane("%1", .error, at: 30),
        pane("%2", .permission, at: 20),
      ]
    )
    #expect(resolved?.category == .needsAttention)
    #expect(resolved?.state == .error)
    #expect(resolved?.paneID == PaneID(rawValue: "%1"))
  }

  @Test("同分類・同時刻なら入力順の先頭を代表とする (決定的であること)")
  func tieIsResolvedDeterministically() {
    let panes = [
      pane("%0", .question, at: 5),
      pane("%1", .permission, at: 5),
    ]
    #expect(resolveWorktreeRepresentativeState(panes: panes)?.paneID == PaneID(rawValue: "%0"))
    #expect(
      resolveWorktreeRepresentativeState(panes: panes.reversed())?.paneID
        == PaneID(rawValue: "%1")
    )
  }

  @Test("Working がある worktree で Unknown pane は代表にならない")
  func workingBeatsUnknown() {
    let resolved = resolveWorktreeRepresentativeState(
      panes: [
        pane("%0", .unknown, at: 100),
        pane("%1", .working, at: 0),
      ]
    )
    #expect(resolved?.state == .working)
  }

  @Test("Unknown と Idle しか無い worktree は Idle ではなく Unknown を代表とする (§12.3)")
  func unknownIsNotRoundedDownToIdle() {
    let resolved = resolveWorktreeRepresentativeState(
      panes: [
        pane("%0", .idle, at: 100),
        pane("%1", .unknown, at: 0),
      ]
    )
    #expect(resolved?.state == .unknown)
    #expect(resolved?.category == .unknown)
  }

  @Test("すべて Unknown なら代表も Unknown であり、Working へ昇格しない (§12.3)")
  func allUnknownStaysUnknown() {
    let resolved = resolveWorktreeRepresentativeState(
      panes: [
        pane("%0", .unknown, at: 0),
        pane("%1", .unknown, at: 10),
      ]
    )
    #expect(resolved?.category == .unknown)
    #expect(resolved?.paneID == PaneID(rawValue: "%1"))
  }

  @Test("入力順を変えても代表状態は変わらない")
  func resultIsIndependentOfInputOrder() {
    let panes = [
      pane("%0", .idle, at: 0),
      pane("%1", .working, at: 10),
      pane("%2", .permission, at: 20),
      pane("%3", .unknown, at: 30),
    ]
    let forward = resolveWorktreeRepresentativeState(panes: panes)
    let backward = resolveWorktreeRepresentativeState(panes: panes.reversed())
    #expect(forward == backward)
    #expect(forward?.state == .permission)
  }

  @Test(
    "すべての AgentState が単一 pane worktree の代表状態になれる",
    arguments: AgentState.allCases
  )
  func everyStateCanBeRepresentative(state: AgentState) {
    let resolved = resolveWorktreeRepresentativeState(panes: [pane("%0", state)])
    #expect(resolved?.state == state)
    #expect(resolved?.category == state.worktreeCategory)
  }
}
