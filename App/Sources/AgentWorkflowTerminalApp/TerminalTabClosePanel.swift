import SwiftUI

struct TerminalTabClosePanelHost: View {
  @ObservedObject var closing: TerminalTabClosing
  let confirm: () -> Void

  var body: some View {
    if let confirmation = closing.confirmation {
      VStack(alignment: .leading, spacing: 8) {
        Text("タブを閉じる: \(confirmation.title)").font(.headline)
        Text(
          confirmation.activity == .running
            ? "このタブの session では shell 以外のプロセスが動いています。閉じるとそのプロセスも終了します。"
            : "このタブの session で動いているプロセスを確認できませんでした。閉じると、動いているプロセスも終了します。")
        HStack {
          Spacer()
          Button("キャンセル") { closing.cancel() }
          Button("タブを閉じる") { confirm() }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.secondary.opacity(0.08))
      Divider()
    }
  }
}
