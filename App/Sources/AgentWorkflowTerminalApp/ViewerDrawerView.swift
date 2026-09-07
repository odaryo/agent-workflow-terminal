import SwiftUI
import TerminalCore

struct ViewerDrawerView<Terminal: View>: View {
  @Binding var layout: ViewerDrawerLayout
  @ViewBuilder let terminal: () -> Terminal

  var body: some View {
    switch layout.presentation {
    case .inline:
      HSplitView {
        terminal().frame(minWidth: 320)
        drawer.frame(minWidth: 240)
      }
    case .overlay:
      ZStack(alignment: .trailing) {
        terminal()
        drawer
          .frame(minWidth: 240, idealWidth: 420, maxWidth: 520)
          .background(.regularMaterial)
          .shadow(radius: 8)
      }
    case .fullscreen:
      drawer
    case nil:
      terminal()
    }
  }

  @ViewBuilder
  private var drawer: some View {
    if let primary = layout.primary {
      if let secondary = layout.secondary {
        switch layout.splitAxis {
        case .horizontal:
          HSplitView {
            pane(primary, isPrimary: true)
            pane(secondary, isPrimary: false)
          }
        case .vertical:
          VSplitView {
            pane(primary, isPrimary: true)
            pane(secondary, isPrimary: false)
          }
        }
      } else {
        pane(primary, isPrimary: true)
      }
    }
  }

  private func pane(_ content: ViewerContent, isPrimary: Bool) -> some View {
    VStack(spacing: 0) {
      HStack {
        Label(content.title, systemImage: content.systemImage)
          .fontWeight(.medium)
        Spacer()
        Button("閉じる", systemImage: "xmark") {
          if isPrimary {
            layout.closePrimary()
          } else {
            layout.closeSecondary()
          }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
      }
      .padding(8)
      Divider()
      ContentUnavailableView(content.title, systemImage: content.systemImage)
    }
    .frame(minWidth: 160, minHeight: 160)
  }
}

extension ViewerContent {
  fileprivate var title: String {
    switch self {
    case .code: "Code"
    case .diff: "Diff"
    case .evidence: "Evidence"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .code: "doc.text"
    case .diff: "arrow.left.arrow.right"
    case .evidence: "checkmark.seal"
    }
  }
}
