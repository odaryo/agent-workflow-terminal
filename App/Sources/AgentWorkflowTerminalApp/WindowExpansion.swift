import AppKit
import SwiftUI

// contentMinSize は SwiftUI に上書きされたため設定せず、拡幅だけを行う (#430 計測)。
struct WindowExpansion: NSViewRepresentable {
  let size: NSSize

  nonisolated static func expandedWidth(
    current: CGFloat, minimum: CGFloat, visible: CGFloat
  ) -> CGFloat {
    max(current, min(minimum, visible))
  }

  func makeNSView(context: Context) -> ExpansionView {
    ExpansionView(size: size)
  }

  func updateNSView(_ view: ExpansionView, context: Context) {
    view.minimumSize = size
    view.scheduleUpdate()
  }

  @MainActor
  final class ExpansionView: NSView {
    var minimumSize: NSSize

    init(size: NSSize) {
      minimumSize = size
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduleUpdate()
    }

    func scheduleUpdate() {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.expandIfNeeded() }
      }
    }

    private func expandIfNeeded() {
      guard let window else { return }
      if let visibleFrame = window.screen?.visibleFrame {
        var frame = window.frame
        let minimumFrame = window.frameRect(
          forContentRect: NSRect(origin: .zero, size: minimumSize))
        let width = WindowExpansion.expandedWidth(
          current: frame.width, minimum: minimumFrame.width, visible: visibleFrame.width)
        if width > frame.width {
          frame.size.width = width
          if frame.maxX > visibleFrame.maxX {
            frame.origin.x = max(visibleFrame.minX, visibleFrame.maxX - width)
          }
          window.setFrame(frame, display: true)
        }
      }
    }
  }
}

struct ProjectWindowExpansion: View {
  @ObservedObject var model: AppModel

  var body: some View {
    WindowExpansion(
      size: NSSize(
        width: ViewerDrawerMetrics.minimumWindowWidth(for: model.viewerDrawerLayout), height: 320))
  }
}

struct ProjectMinimumWindowWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 480

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

struct ProjectWindowWidthPreference: ViewModifier {
  @ObservedObject var model: AppModel

  func body(content: Content) -> some View {
    content.preference(
      key: ProjectMinimumWindowWidthKey.self,
      value: ViewerDrawerMetrics.minimumWindowWidth(for: model.viewerDrawerLayout))
  }
}
