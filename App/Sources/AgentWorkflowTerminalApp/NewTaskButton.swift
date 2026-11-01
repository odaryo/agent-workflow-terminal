import SwiftUI
import TerminalCore

@MainActor
struct NewTaskButton: View {
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    // Why not `Label` + `.labelStyle(.iconOnly)`: 実測で AX の title / description が
    // 空になり (#407 の UI 確認)、当たり判定もアイコンの 10x10pt しか無かった。
    Button(action: action) {
      Image(systemName: "plus")
        .frame(width: 22, height: 22)
        .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("新しいタブ (Project Root)")
    .disabled(isDisabled)
    .help(
      isDisabled
        ? "bare repository には Project Root の端末が無いため使えません。"
        : "Project Root のディレクトリで新しいタブを開きます。Agent は起動しません。")
  }
}

extension ProjectView {
  func openNewProjectRootTab() {
    guard let identity = model.projectRoot?.identity else { return }
    openNewTab(in: identity)
  }

  func openNewTab(in identity: WorktreeIdentity) {
    Task {
      await model.openNewTab(in: identity)
      keyboardFocus.requestFocus()
    }
  }
}
