/// `hostctl worktree open` で作業を渡し終えた pane の記録 (設計書 §3.1、§13)。
///
/// - Important: 記録はアプリの寿命だけ持ち、再起動で消える。
/// - Note: 解除は生の観測状態で判定する。`hostctl worktree open` は Agent のターンの途中
///   (`Working`) で呼ばれるので、記録より前の状態を引き継ぐと、そのターンの `Working` で
///   すぐに消えてしまう。記録の後に観測した `Idle` / `Completed` からの `Working` だけで解除する。
/// - Note: `Unknown` と観測なし (`nil`) で直前の既知の状態を上書きしない。Claude Code ではユーザーが
///   次の指示を打っている間 `Unknown` になり、流れが `Completed` → `Unknown` → `Working` になるため、
///   上書きすると一度も解除されない (§12.7 のタスク完了表示の解除と同じ)。
public struct PaneHandoffTracker: Sendable {
  private struct Entry: Sendable {
    var processID: Int32?
    var lastKnownState: AgentState?
  }

  private static let turnEndingStates: Set<AgentState> = [.idle, .completed]

  private var entries: [PaneID: Entry] = [:]

  public init() {}

  /// `processID` は記録した時点の `#{pane_pid}`。分からなければ `nil` を渡し、
  /// `paneProcessObserved` で最初に観測した値を採る。
  public mutating func record(paneID: PaneID, processID: Int32?) {
    entries[paneID] = Entry(processID: processID)
  }

  /// `agentState` は adapter の観測そのもの (`PaneAgentState.state`) を渡す。
  public mutating func update(paneID: PaneID, agentState: AgentState?) -> Bool {
    guard var entry = entries[paneID] else { return false }
    if agentState == .working, let previous = entry.lastKnownState,
      Self.turnEndingStates.contains(previous)
    {
      entries.removeValue(forKey: paneID)
      return false
    }
    if let agentState, agentState != .unknown {
      entry.lastKnownState = agentState
    }
    entries[paneID] = entry
    return true
  }

  /// tmux server が再起動すると `%N` が別の pane へ振り直されるので、`#{pane_pid}` が記録と
  /// 違えば別の pane とみなして記録を消す。
  public mutating func paneProcessObserved(paneID: PaneID, processID: Int32) {
    guard var entry = entries[paneID] else { return }
    guard let recorded = entry.processID else {
      entry.processID = processID
      entries[paneID] = entry
      return
    }
    if recorded != processID {
      entries.removeValue(forKey: paneID)
    }
  }

  public func isHandedOff(paneID: PaneID) -> Bool {
    entries[paneID] != nil
  }

  public mutating func forget(paneID: PaneID) {
    entries.removeValue(forKey: paneID)
  }
}
