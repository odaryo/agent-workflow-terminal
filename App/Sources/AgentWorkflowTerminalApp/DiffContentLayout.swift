import SwiftUI

private enum DiffContentMetrics {
  static let fileListWidth: CGFloat = 240
  static let diffMinimumWidth: CGFloat = 200
  static let commentsWidth: CGFloat = 260
  static let dividerThickness: CGFloat = 1
  static let wideMinimumWidth =
    fileListWidth + diffMinimumWidth + commentsWidth + dividerThickness * 2
  static let fileListHeight: CGFloat = 140
  static let commentsHeight: CGFloat = 220
}

struct DiffContentLayout<FileList: View, Diff: View, Comments: View>: View {
  @ViewBuilder var fileList: () -> FileList
  @ViewBuilder var diff: () -> Diff
  @ViewBuilder var comments: () -> Comments

  var body: some View {
    GeometryReader { proxy in
      let wide = proxy.size.width >= DiffContentMetrics.wideMinimumWidth
      // 条件分岐でビューを作り直すと、コメント入力のフォーカスや一覧の位置が失われる。
      let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        fileList()
          .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
          .frame(
            width: wide ? DiffContentMetrics.fileListWidth : nil,
            height: wide ? nil : DiffContentMetrics.fileListHeight)
        divider(wide: wide)
        diff()
          .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        divider(wide: wide)
        comments()
          .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
          .frame(
            width: wide ? DiffContentMetrics.commentsWidth : nil,
            height: wide ? nil : DiffContentMetrics.commentsHeight)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }

  private func divider(wide: Bool) -> some View {
    Divider()
      .frame(
        width: wide ? DiffContentMetrics.dividerThickness : nil,
        height: wide ? nil : DiffContentMetrics.dividerThickness)
  }
}
