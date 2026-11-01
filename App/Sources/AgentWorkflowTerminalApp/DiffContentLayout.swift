import SwiftUI
import TerminalCore

enum DiffContentMetrics {
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
  let arrangement: ViewerContentArrangement
  @ViewBuilder var fileList: () -> FileList
  @ViewBuilder var diff: () -> Diff
  @ViewBuilder var comments: () -> Comments

  var body: some View {
    switch arrangement {
    case .sideBySide:
      HStack(spacing: 0) {
        fileList()
          .frame(width: DiffContentMetrics.fileListWidth)
        Divider().frame(width: DiffContentMetrics.dividerThickness)
        diff()
          .frame(minWidth: DiffContentMetrics.diffMinimumWidth, maxWidth: .infinity)
        Divider().frame(width: DiffContentMetrics.dividerThickness)
        comments()
          .frame(width: DiffContentMetrics.commentsWidth)
      }
      .frame(maxHeight: .infinity)
    case .stacked:
      VSplitView {
        fileList()
          .frame(
            minHeight: 60, idealHeight: DiffContentMetrics.fileListHeight, maxHeight: .infinity)
        diff()
          .frame(minWidth: 0, maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
        comments()
          .frame(
            minHeight: 80, idealHeight: DiffContentMetrics.commentsHeight, maxHeight: .infinity)
      }
    }
  }
}
