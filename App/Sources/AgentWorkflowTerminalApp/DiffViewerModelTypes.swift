import TerminalCore

extension DiffViewerModel {
  enum Kind: Hashable, CaseIterable {
    case commit
    case base
    case branch
  }

  struct FileSelection: Hashable {
    let origin: DiffChangeOrigin
    let path: String
  }

  /// コメントを付ける対象として選ばれている行 (§9.2)。単一行も1行の範囲として持つ。
  struct LineSelection: Equatable {
    let file: FileSelection
    let side: DiffLineSide
    var range: DiffLineRange
  }

  var baseBranchDescription: String {
    switch baseBranch {
    case .resolved(let branch, let source): "\(branch.displayLabel) (\(source.decisionLabel))"
    case .undetermined: "未決定"
    }
  }

  func isSelected(line: Int, side: DiffLineSide) -> Bool {
    guard let lineSelection, lineSelection.side == side, lineSelection.file == selection else {
      return false
    }
    return lineSelection.range.lineNumbers.contains(line)
  }

  var currentSnapshot: DiffSnapshot? {
    guard let currentSnapshotID else { return history.latest }
    return history.snapshot(currentSnapshotID)
  }

  var isViewingOldSnapshot: Bool {
    guard let current = currentSnapshot, let latest = history.latest else { return false }
    return current.id != latest.id
  }
}
