import Foundation

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
  public var title: String?
  public var isHandedOff: Bool

  public init(
    location: PaneLocation? = nil, purpose: String? = nil, status: String? = nil,
    isTaskCompleted: Bool = false, title: String? = nil, isHandedOff: Bool = false
  ) {
    self.location = location
    self.purpose = purpose
    self.status = status
    self.isTaskCompleted = isTaskCompleted
    self.title = title
    self.isHandedOff = isHandedOff
  }

  /// 1行に出せない値を表示しないため、前後の空白と改行を除いた後に残った制御文字 (Cc) と行区切りを拒否する
  /// (設計書 §12.7)。`@awt_*` の読み取りと違い、末尾の CR などは除いて受理する。
  /// 記号直後の空白除去で改行や制御文字が消えて拒否をすり抜けないよう、接頭辞の除去前に検証する。
  /// fish の `~/…` などを壊さないよう接頭辞の記号は So に限り、`★重要` のような語の一部を
  /// 削らないよう直後に空白がある場合だけ除く。
  public static func displayTitle(fromPaneTitle raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.unicodeScalars.contains(where: PaneSummaryFormatViolation.breaksSingleLine)
    else { return nil }
    let symbols = trimmed.prefix {
      $0.unicodeScalars.first?.properties.generalCategory == .otherSymbol
    }
    let whitespace = trimmed[symbols.endIndex...].prefix { $0.isWhitespace }
    let title =
      if !symbols.isEmpty && !whitespace.isEmpty {
        String(trimmed[whitespace.endIndex...])
      } else {
        trimmed
      }
    guard !PaneSummaryFormatViolation.isInvisibleOnly(title) else { return nil }
    return title
  }
}

public struct OverviewWorktreeInput: Sendable {
  public var session: TerminalSessionKey
  public var worktree: WorktreeIdentity { session.identity }
  /// Agent pane だけ。`.absent` の pane は観測の時点で除かれている (§5.2)。
  public var paneStates: [PaneDisplayState]
  /// 非 Agent pane の概要が混ざってよい。行にするかは `paneStates` だけで決める。
  public var details: [PaneID: OverviewPaneDetail]
  public var mainPane: PaneID?
  public var isObserved: Bool

  public init(
    session: TerminalSessionKey, paneStates: [PaneDisplayState],
    details: [PaneID: OverviewPaneDetail] = [:], mainPane: PaneID? = nil,
    isObserved: Bool = true
  ) {
    self.session = session
    self.paneStates = paneStates
    self.details = details
    self.mainPane = mainPane
    self.isObserved = isObserved
  }

  public init(
    worktree: WorktreeIdentity, paneStates: [PaneDisplayState],
    details: [PaneID: OverviewPaneDetail] = [:], mainPane: PaneID? = nil,
    isObserved: Bool = true
  ) {
    self.init(
      session: .primary(worktree), paneStates: paneStates, details: details, mainPane: mainPane,
      isObserved: isObserved)
  }
}

public struct OverviewProjectInput: Sendable {
  public var project: WorktreeIdentity
  /// Project Root のタブの順。出力もこの順のままで、状態では並べ替えない (設計書 §13)。
  public var projectRootSessions: [OverviewWorktreeInput]
  /// 開いた順で渡す。同じ worktree の session は別々の要素として
  /// 渡し、束ねない (設計書 §12.2)。
  public var tasks: [OverviewWorktreeInput]

  public var projectRoot: OverviewWorktreeInput? { projectRootSessions.first }

  public init(
    project: WorktreeIdentity, projectRootSessions: [OverviewWorktreeInput],
    tasks: [OverviewWorktreeInput]
  ) {
    self.project = project
    self.projectRootSessions = projectRootSessions
    self.tasks = tasks
  }

  public init(
    project: WorktreeIdentity, projectRoot: OverviewWorktreeInput?,
    tasks: [OverviewWorktreeInput]
  ) {
    self.init(project: project, projectRootSessions: projectRoot.map { [$0] } ?? [], tasks: tasks)
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
  /// 未観測を Agent 不在と誤認させないため、観測済みの空行と区別する (設計書 §13)。
  case notObserved

  public var pane: OverviewPane? {
    guard case .pane(let pane) = self else { return nil }
    return pane
  }
}

public struct OverviewWorktree: Sendable, Hashable {
  public let session: TerminalSessionKey
  public var worktree: WorktreeIdentity { session.identity }
  /// 空にならない。未観測は `[.notObserved]`、観測済みで Agent pane が無ければ `[.noAgentPane]`。
  public let rows: [OverviewRow]
}

public struct OverviewProject: Sendable, Hashable {
  public let project: WorktreeIdentity
  /// 入力の順のまま。
  public let projectRootSessions: [OverviewWorktree]
  public let tasks: [OverviewWorktree]

  public var projectRoot: OverviewWorktree? { projectRootSessions.first }
}

public struct TabSummary: Sendable, Hashable {
  public let session: TerminalSessionKey
  public let rows: [OverviewRow]
}

/// 入力は session を開いた順、pane を tmux 上の順で渡す (設計書 §13)。
public func makeTabSummaries(_ tabs: [OverviewWorktreeInput]) -> [TabSummary] {
  tabs.map { input in
    let overview = overviewWorktree(input)
    return TabSummary(session: overview.session, rows: overview.rows)
  }
}

/// 状態の変化で見ている場所が動かないよう、入力は Project をユーザーが並べ替えた順、session を開いた順、
/// pane を tmux 上の順で渡す。Project Root は Task と混ぜず別枠に置く (設計書 §13)。
public func makeAgentPaneOverview(_ projects: [OverviewProjectInput]) -> [OverviewProject] {
  projects.map { project in
    OverviewProject(
      project: project.project,
      projectRootSessions: project.projectRootSessions.map(overviewWorktree),
      tasks: project.tasks.map(overviewWorktree))
  }
}

private func overviewWorktree(_ input: OverviewWorktreeInput) -> OverviewWorktree {
  guard input.isObserved else {
    return OverviewWorktree(session: input.session, rows: [.notObserved])
  }
  let panes = input.paneStates.map { state in
    OverviewRow.pane(
      OverviewPane(
        display: state,
        detail: input.details[state.paneID] ?? OverviewPaneDetail(),
        isMain: state.paneID == input.mainPane))
  }
  return OverviewWorktree(session: input.session, rows: panes.isEmpty ? [.noAgentPane] : panes)
}
