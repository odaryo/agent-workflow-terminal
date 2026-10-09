import SwiftUI

struct WarningBar: View {
  let text: String
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle")
      Text(text).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 8)
      Button("閉じる", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.orange.opacity(0.15))
  }
}
