import SwiftUI

@MainActor
struct NewTaskButton: View {
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    // Why not `NewTaskMenuItem` + `.labelStyle(.iconOnly)`: 実測で AX の title / description が
    // 空になり (#407 の UI 確認)、当たり判定もアイコンの 10x10pt しか無かった。
    Button(action: action) {
      Image(systemName: "plus")
        .frame(width: 22, height: 22)
        .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(NewTaskMenuItem.title)
    .disabled(isDisabled)
    .help(NewTaskMenuItem.help(isDisabled: isDisabled))
  }
}

@MainActor
struct NewTaskMenuItem: View {
  let isDisabled: Bool
  let action: () -> Void

  static let title = "新しいタスク…"

  static func help(isDisabled: Bool) -> String {
    isDisabled
      ? "bare repository には Project Root の端末が無いため使えません。"
      : "Project Root の端末へ移ります。そこで Agent を起動して worktree を作らせると、新しいタブとして現れます。"
  }

  var body: some View {
    Button(Self.title, systemImage: "plus", action: action)
      .disabled(isDisabled)
      .help(Self.help(isDisabled: isDisabled))
  }
}

extension ProjectView {
  func startNewTask() {
    guard model.projectRoot != nil else { return }
    model.startNewTask()
    // 同じタブを選び直す場合は selectedIdentity の onChange が発火しない。
    keyboardFocus.requestFocus()
  }
}
