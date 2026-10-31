import SwiftUI

@MainActor
struct NewTaskButton: View {
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    NewTaskMenuItem(isDisabled: isDisabled, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
  }
}

@MainActor
struct NewTaskMenuItem: View {
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    Button("新しいタスク…", systemImage: "plus", action: action)
      .disabled(isDisabled)
      .help(
        isDisabled
          ? "bare repository には Project Root の端末が無いため使えません。"
          : "Project Root の端末へ移ります。そこで Agent を起動して worktree を作らせると、新しいタブとして現れます。"
      )
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
