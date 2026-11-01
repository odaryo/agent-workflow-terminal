import SwiftUI
import TerminalCore

struct ViewerDrawerToolbar: View {
  @Binding var layout: ViewerDrawerLayout

  var body: some View {
    HStack(spacing: 4) {
      Menu("Viewer", systemImage: "sidebar.right") {
        ForEach(ViewerContent.allCases, id: \.self) { content in
          Button(content.toolbarTitle) { layout.open(content) }
        }
      }
      .menuStyle(.borderlessButton)

      if layout.isOpen {
        if let content = layout.content, let arrangement = layout.arrangement(for: content) {
          Picker(
            "中身の並び",
            selection: Binding(
              get: { arrangement },
              set: { layout.setArrangement($0, for: content) })
          ) {
            Label("左右", systemImage: "rectangle.split.2x1")
              .accessibilityLabel("左右に並べる")
              .help("左右に並べる")
              .tag(ViewerContentArrangement.sideBySide)
            Label("上下", systemImage: "rectangle.split.1x2")
              .accessibilityLabel("上下に並べる")
              .help("上下に並べる")
              .tag(ViewerContentArrangement.stacked)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }

        Button("Viewer を閉じる", systemImage: "xmark") { layout.close() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
    }
  }
}

private extension ViewerContent {
  var toolbarTitle: String {
    switch self {
    case .code: "Code"
    case .diff: "Diff"
    case .evidence: "Evidence"
    }
  }
}
