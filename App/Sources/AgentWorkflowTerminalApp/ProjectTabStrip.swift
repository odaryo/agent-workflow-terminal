import SwiftUI

struct ProjectTabStrip<Content: View, Target: Hashable>: View {
  /// 見える位置へ寄せるタブの id。タブ側は同じ値を `.id(_:)` に持つこと。
  let scrollTarget: Target?
  @ViewBuilder let content: Content

  // toolbar 項目から window 幅を GeometryReader で取得できないため、固定上限で
  // タブの増加が window をドラッグする余白を使い切るのを避ける。
  private let maximumWidth: CGFloat = 480

  var body: some View {
    ViewThatFits(in: .horizontal) {
      content
      // スクロールの表示を隠しているので、寄せないと新規タブで足したタブが上限の外に置かれた
      // まま見えず、選ばれていることも分からない (#457 の UI 確認)。
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          content
        }
        .scrollIndicators(.hidden)
        .onAppear { reveal(scrollTarget, with: proxy) }
        .onChange(of: scrollTarget) { _, target in reveal(target, with: proxy) }
      }
      .frame(maxWidth: maximumWidth)
    }
    .frame(maxWidth: maximumWidth)
    .fixedSize(horizontal: true, vertical: true)
  }

  private func reveal(_ target: Target?, with proxy: ScrollViewProxy) {
    guard let target else { return }
    withAnimation { proxy.scrollTo(target) }
  }
}
