import SwiftUI

struct TerminalSessionClosePanelHost: View {
  @ObservedObject var closing: TerminalSessionClosing
  let confirm: () -> Void

  var body: some View {
    if let confirmation = closing.confirmation {
      VStack(alignment: .leading, spacing: 8) {
        Text("セッションを閉じる: \(confirmation.title)").font(.headline)
        Text(
          confirmation.activity == .running
            ? "このセッションでは shell 以外のプロセスが動いています。閉じるとそのプロセスも終了します。"
            : "このセッションで動いているプロセスを確認できませんでした。閉じると、動いているプロセスも終了します。")
        HStack {
          Spacer()
          Button("キャンセル") { closing.cancel() }
          Button("セッションを閉じる") { confirm() }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.secondary.opacity(0.08))
      Divider()
    }
  }
}
