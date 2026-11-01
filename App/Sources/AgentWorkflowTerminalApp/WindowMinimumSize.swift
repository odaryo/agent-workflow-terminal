import AppKit
import SwiftUI

struct WindowMinimumSize: NSViewRepresentable {
  let size: NSSize

  nonisolated static func expandedWidth(
    current: CGFloat, minimum: CGFloat, visible: CGFloat
  ) -> CGFloat {
    max(current, min(minimum, visible))
  }

  func makeNSView(context: Context) -> MinimumSizeView {
    MinimumSizeView(size: size)
  }

  func updateNSView(_ view: MinimumSizeView, context: Context) {
    view.minimumSize = size
    view.scheduleUpdate()
  }

  @MainActor
  final class MinimumSizeView: NSView {
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
        MainActor.assumeIsolated { self?.applyMinimumSize() }
      }
    }

    private func applyMinimumSize() {
      guard let window else { return }
      if let visibleFrame = window.screen?.visibleFrame {
        var frame = window.frame
        let minimumFrame = window.frameRect(
          forContentRect: NSRect(origin: .zero, size: minimumSize))
        let width = WindowMinimumSize.expandedWidth(
          current: frame.width, minimum: minimumFrame.width, visible: visibleFrame.width)
        if width > frame.width {
          frame.size.width = width
          if frame.maxX > visibleFrame.maxX {
            frame.origin.x = max(visibleFrame.minX, visibleFrame.maxX - width)
          }
          window.setFrame(frame, display: true)
        }
      }
      // SwiftUI の内側の frame(minWidth:) は実測で window の縮小を止めなかった (#430)。
      // レイアウトの最小幅に頼らず、AppKit のリサイズ制約へ直接反映する。
      window.contentMinSize = minimumSize
    }
  }
}

struct ProjectWindowMinimumSize: View {
  @ObservedObject var model: AppModel

  var body: some View {
    WindowMinimumSize(
      size: NSSize(
        width: ViewerDrawerMetrics.minimumWindowWidth(for: model.viewerDrawerLayout), height: 320))
  }
}
