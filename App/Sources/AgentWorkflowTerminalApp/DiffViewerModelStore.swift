import SwiftUI

/// worktree ごとの `DiffViewerModel` を Drawer の開閉より長く持たせるための入れ物。
@MainActor
final class DiffViewerModelStore: ObservableObject {
  private var models: [URL: DiffViewerModel] = [:]
  /// 持ち主の `AppModel` が自分の一覧から答える。持ち主より先に作られるため後から設定する。
  var worktreeContext: @MainActor (URL) -> DiffWorktreeContext = { root in
    DiffWorktreeContext(displayName: root.lastPathComponent, otherTasks: [])
  }

  func model(for worktreeRoot: URL) -> DiffViewerModel {
    if let existing = models[worktreeRoot] { return existing }
    let model = DiffViewerModel(
      worktreeRoot: worktreeRoot,
      worktreeContext: { [weak self] in
        self?.worktreeContext(worktreeRoot)
          ?? DiffWorktreeContext(displayName: worktreeRoot.lastPathComponent, otherTasks: [])
      })
    models[worktreeRoot] = model
    return model
  }
}
