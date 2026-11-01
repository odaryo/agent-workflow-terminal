import AppKit
import SwiftUI

// contentMinSize は SwiftUI に上書きされるため KVO で下限を入れ直す。
// preference の経路では値が SwiftUI の root へ届かなかった (#477 計測)。
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
    var minimumSize: NSSize {
      didSet { applyMinimumSize() }
    }
    private var minimumSizeObservation: NSKeyValueObservation?
    private var swiftUIMinimumSize: NSSize = .zero
    private var isApplyingMinimumSize = false

    init(size: NSSize) {
      minimumSize = size
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      minimumSizeObservation?.invalidate()
      minimumSizeObservation = nil
      if let window {
        swiftUIMinimumSize = window.contentMinSize
        minimumSizeObservation = window.observe(
          \.contentMinSize, options: [.new]
        ) { [weak self] window, change in
          // NSWindow の UI プロパティの変更は main thread 上で同期通知される。
          MainActor.assumeIsolated {
            guard let self, self.window === window, !self.isApplyingMinimumSize,
              let size = change.newValue
            else { return }
            self.swiftUIMinimumSize = size
            self.applyMinimumSize()
          }
        }
        applyMinimumSize()
      }
      scheduleUpdate()
    }

    func scheduleUpdate() {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          self?.applyMinimumSize()
          self?.expandIfNeeded()
        }
      }
    }

    private func applyMinimumSize() {
      guard let window else { return }
      // 補正した値を基準にすると、Drawer を閉じても下限を下げられなくなる。
      let size = NSSize(
        width: max(swiftUIMinimumSize.width, minimumSize.width),
        height: max(swiftUIMinimumSize.height, minimumSize.height))
      guard window.contentMinSize != size else { return }
      isApplyingMinimumSize = true
      defer { isApplyingMinimumSize = false }
      window.contentMinSize = size
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
