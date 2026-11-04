import AppKit
import SwiftUI

// Icon and Label は Project メニューの Label の title をアイコンの下に描き、ツールバーが2段になる (#583)。
// #431 の「Icon Only でタブ名が消える」は各 Label に labelStyle(.titleAndIcon) を明示する前の記録で、
// 今は消えない (#583 で実測)。macOS 14 は allowsDisplayModeCustomization が無く、表示形式メニューが残る。
// SceneBuilder は if #available を扱えず、windowToolbarLabelStyle(fixed:) を macOS 14 と両立できない。
@MainActor
struct ToolbarDisplayModeLock: NSViewRepresentable {
  func makeNSView(context: Context) -> ToolbarView {
    ToolbarView(frame: .zero)
  }

  func updateNSView(_ view: ToolbarView, context: Context) {
    view.scheduleUpdate()
  }

  @MainActor
  final class ToolbarView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduleUpdate()
    }

    func scheduleUpdate() {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.applyDisplayMode() }
      }
    }

    private func applyDisplayMode() {
      guard let toolbar = window?.toolbar else { return }
      toolbar.displayMode = .iconOnly
      if #available(macOS 15, *) {
        toolbar.allowsDisplayModeCustomization = false
      }
    }
  }
}
