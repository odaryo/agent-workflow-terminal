/// tmux の `#{window_index}` と `#{pane_index}`。pane の短い識別として表示する (設計書 §13)。
/// `PaneID` と違い、pane の分割・削除で振り直される。
public struct PaneLocation: Sendable, Hashable {
  public let windowIndex: Int
  public let paneIndex: Int

  public init(windowIndex: Int, paneIndex: Int) {
    self.windowIndex = windowIndex
    self.paneIndex = paneIndex
  }
}

/// pane 1つの概要 (設計書 §12.7)。`nil` はどれも「表示しない」。
public struct OverviewPaneDetail: Sendable, Hashable {
  public var location: PaneLocation?
  /// 手入力の目的 (`@awt_purpose`)。
  public var purpose: String?
  /// 連携由来の現在地 (`@awt_status`)。受理された値だけを入れる — 未受理の値を推測で埋めない。
  public var status: String?
  /// ハーネスの明示信号によるタスク完了 (`PaneTaskCompletionDisplay.completed`)。pane の
  /// 応答終了 (`AgentState.completed`) とは別 (§12.7)。
  public var isTaskCompleted: Bool

  public init(
    location: PaneLocation? = nil, purpose: String? = nil, status: String? = nil,
    isTaskCompleted: Bool = false
  ) {
    self.location = location
    self.purpose = purpose
    self.status = status
    self.isTaskCompleted = isTaskCompleted
  }
}

public struct OverviewWorktreeInput: Sendable {
  public var worktree: WorktreeIdentity
  /// Agent pane だけ。`.absent` の pane は観測の時点で除かれている (§5.2)。
  public var paneStates: [PaneDisplayState]
  /// 非 Agent pane の概要が混ざってよい。行にするかは `paneStates` だけで決める。
  public var details: [PaneID: OverviewPaneDetail]
  public var mainPane: PaneID?

  public init(
    worktree: WorktreeIdentity, paneStates: [PaneDisplayState],
    details: [PaneID: OverviewPaneDetail] = [:], mainPane: PaneID? = nil
  ) {
    self.worktree = worktree
    self.paneStates = paneStates
    self.details = details
    self.mainPane = mainPane
  }
}

public struct OverviewProjectInput: Sendable {
  public var project: WorktreeIdentity
  public var projectRoot: OverviewWorktreeInput?
  /// tab の順。並べ替えの同順位はこの順を保つ。
  public var tasks: [OverviewWorktreeInput]

  public init(
    project: WorktreeIdentity, projectRoot: OverviewWorktreeInput?,
    tasks: [OverviewWorktreeInput]
  ) {
    self.project = project
    self.projectRoot = projectRoot
    self.tasks = tasks
  }
}

public struct OverviewPane: Sendable, Hashable {
  public let display: PaneDisplayState
  public let detail: OverviewPaneDetail
  public let isMain: Bool

  public var paneID: PaneID { display.paneID }
}

public enum OverviewRow: Sendable, Hashable {
  case pane(OverviewPane)
  /// Agent pane が1つも無い worktree の行。
  case noAgentPane

  public var pane: OverviewPane? {
    guard case .pane(let pane) = self else { return nil }
    return pane
  }
}

public struct OverviewWorktree: Sendable, Hashable {
  public let worktree: WorktreeIdentity
  /// 空にならない。Agent pane が無ければ `[.noAgentPane]`。
  public let rows: [OverviewRow]
}

public struct OverviewProject: Sendable, Hashable {
  public let project: WorktreeIdentity
  public let projectRoot: OverviewWorktree?
  public let tasks: [OverviewWorktree]
}

/// 設計書 §13 の並び順。
///
/// - Project は入力 (登録) の順で固定する。並べ替えると、見ている場所が状態の変化で動く。
/// - Project Root は Task と混ぜず別枠に置く。
/// - Task は Needs Attention の pane を含むものを先に、それぞれ pane の最終更新の最大値が新しい順。
///   Agent pane の無い Task は最後。同順位は入力 (tab) の順。
/// - Task 内の pane は Needs Attention を先に、それぞれ最終更新の新しい順。同順位は入力の順。
///
/// - Important: Needs Attention は `category` で判定する。`state` で `Question` / `Permission` /
///   `Error` を列挙すると、種別不明の注意状態 (§12.4.3) が後ろへ沈む。
public func makeAgentPaneOverview(_ projects: [OverviewProjectInput]) -> [OverviewProject] {
  projects.map { project in
    OverviewProject(
      project: project.project,
      projectRoot: project.projectRoot.map(overviewWorktree),
      tasks: stableSorted(project.tasks.map(overviewWorktree), by: taskPrecedes))
  }
}

private func overviewWorktree(_ input: OverviewWorktreeInput) -> OverviewWorktree {
  let panes = stableSorted(input.paneStates, by: panePrecedes).map { state in
    OverviewRow.pane(
      OverviewPane(
        display: state,
        detail: input.details[state.paneID] ?? OverviewPaneDetail(),
        isMain: state.paneID == input.mainPane))
  }
  return OverviewWorktree(worktree: input.worktree, rows: panes.isEmpty ? [.noAgentPane] : panes)
}

private func panePrecedes(_ lhs: PaneDisplayState, _ rhs: PaneDisplayState) -> Bool {
  let lhsAttention = lhs.category == .needsAttention
  let rhsAttention = rhs.category == .needsAttention
  if lhsAttention != rhsAttention { return lhsAttention }
  return lhs.changedAt > rhs.changedAt
}

private func taskPrecedes(_ lhs: OverviewWorktree, _ rhs: OverviewWorktree) -> Bool {
  let lhsPanes = lhs.rows.compactMap(\.pane)
  let rhsPanes = rhs.rows.compactMap(\.pane)
  if lhsPanes.isEmpty != rhsPanes.isEmpty { return !lhsPanes.isEmpty }
  let lhsAttention = lhsPanes.contains { $0.display.category == .needsAttention }
  let rhsAttention = rhsPanes.contains { $0.display.category == .needsAttention }
  if lhsAttention != rhsAttention { return lhsAttention }
  let lhsLatest = lhsPanes.map(\.display.changedAt).max()
  let rhsLatest = rhsPanes.map(\.display.changedAt).max()
  guard let lhsLatest, let rhsLatest else { return false }
  return lhsLatest > rhsLatest
}

/// `sort(by:)` は安定性を保証しないので、同順位で入力順を保つために添字を鍵へ足す。
private func stableSorted<Element>(
  _ elements: [Element], by precedes: (Element, Element) -> Bool
) -> [Element] {
  elements.enumerated()
    .sorted { lhs, rhs in
      if precedes(lhs.element, rhs.element) { return true }
      if precedes(rhs.element, lhs.element) { return false }
      return lhs.offset < rhs.offset
    }
    .map(\.element)
}
