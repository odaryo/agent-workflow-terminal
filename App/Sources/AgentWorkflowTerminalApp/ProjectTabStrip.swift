import SwiftUI

struct ProjectTabStrip<Content: View>: View {
  @ViewBuilder let content: Content

  // toolbar 項目から window 幅を GeometryReader で取得できないため、固定上限で
  // タブの増加が window をドラッグする余白を使い切るのを避ける。
  private let maximumWidth: CGFloat = 480

  var body: some View {
    ViewThatFits(in: .horizontal) {
      content
      ScrollView(.horizontal) {
        content
      }
      .scrollIndicators(.hidden)
      .frame(maxWidth: maximumWidth)
    }
    .frame(maxWidth: maximumWidth)
    .fixedSize(horizontal: true, vertical: true)
  }
}
