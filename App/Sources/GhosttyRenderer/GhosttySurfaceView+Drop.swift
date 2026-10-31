import AppKit

extension GhosttySurfaceView {
  override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    dropOperation(for: sender)
  }

  override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    dropOperation(for: sender)
  }

  override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard canReceiveFileDrop,
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      let text = TerminalDropText.text(for: urls)
    else { return false }

    sendText(text)
    // Why not wantsKeyboardFocus: 自動取得の調停とは異なり、mouseDown と同じく
    // ユーザーが明示的に選んだ端末を Drawer の入力欄より優先する。
    if let window, window.firstResponder !== self {
      window.makeFirstResponder(self)
    }
    if !NSApp.isActive { NSApp.activate() }
    return true
  }

  private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
    guard canReceiveFileDrop,
      sender.draggingPasteboard.canReadObject(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    else { return [] }
    return .copy
  }

  private var canReceiveFileDrop: Bool {
    guard surface != nil, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
    // Why not hit testing だけ: SwiftUI の allowsHitTesting が AppKit のドラッグ判定にも
    // 効く保証はないため、AppKit から観測できる祖先の透明化も拒否する。
    var ancestor: NSView? = self
    while let view = ancestor {
      guard view.alphaValue > 0 else { return false }
      ancestor = view.superview
    }
    return true
  }
}
