import AppKit
import SwiftUI

// Why not Divider / onHover: 境界の合成ドラッグ18回で幅が変わらず、Divider は横線になった。
// NSView の当たり判定と cursor rect を同じ領域に持たせ、隣の端末のカーソル処理に頼らない。
@MainActor
struct DrawerResizeHandle: NSViewRepresentable {
  let width: CGFloat
  /// Drawer のように右端に付く側は左へ引くと広がる。左側のパネルは右へ引くと広がるので `true`。
  var growsRightward = false
  var accessibilityLabel = "Viewer の幅"
  let onWidthChange: @MainActor (CGFloat) -> Void
  let onDragEnd: @MainActor (CGFloat) -> Void

  func makeNSView(context: Context) -> ResizeHandleView {
    let view = ResizeHandleView()
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.splitter)
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: ResizeHandleView, context: Context) {
    nsView.width = width
    nsView.growsRightward = growsRightward
    nsView.setAccessibilityLabel(accessibilityLabel)
    nsView.onWidthChange = onWidthChange
    nsView.onDragEnd = onDragEnd
  }

  @MainActor
  final class ResizeHandleView: NSView {
    var width: CGFloat = 0
    var growsRightward = false
    var onWidthChange: (@MainActor (CGFloat) -> Void)?
    var onDragEnd: (@MainActor (CGFloat) -> Void)?
    private var dragStart: (width: CGFloat, windowX: CGFloat)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
      NSColor.separatorColor.setFill()
      NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    private func proposedWidth(
      for event: NSEvent, from start: (width: CGFloat, windowX: CGFloat)
    ) -> CGFloat {
      let delta = event.locationInWindow.x - start.windowX
      return growsRightward ? start.width + delta : start.width - delta
    }

    override func mouseDown(with event: NSEvent) {
      dragStart = (width, event.locationInWindow.x)
    }

    override func mouseDragged(with event: NSEvent) {
      guard let dragStart else { return }
      onWidthChange?(proposedWidth(for: event, from: dragStart))
    }

    override func mouseUp(with event: NSEvent) {
      guard let dragStart else { return }
      self.dragStart = nil
      onDragEnd?(proposedWidth(for: event, from: dragStart))
    }
  }
}
