import TerminalCore

extension AppModel {
  /// hostctl の要求で回す回は、直後に Inactive の worktree を Active 化し得るので使い回さない。
  /// 使い回している間は、別 repository への置き換えなど `rev-parse` だけが気づく壊れ方を
  /// 検出できないため (Issue #401)。
  func reusableObservations(isRequestedScan: Bool) -> [DetectedWorktree] {
    guard !isRequestedScan else { return [] }
    return worktrees.filter { $0.activation == .inactive }.map(\.detected)
  }
}
