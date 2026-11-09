import AppKit

extension GhosttySurfaceView {
  func updateFileDropRegistration(
    _ request: TerminalFocusRequest?,
    participation: TerminalKeyboardParticipation
  ) {
    let acceptsDrops = request != nil && participation == .normal
    guard acceptsDrops != acceptsFileDrops else { return }
    acceptsFileDrops = acceptsDrops
    // Why not init で登録: AppKit は SwiftUI の opacity / allowsHitTesting を見ず、
    // 最前面の登録済み NSView を選ぶため、非表示セッションの登録を残すと誤配送される。
    if acceptsDrops {
      registerForDraggedTypes([.fileURL])
    } else {
      unregisterDraggedTypes()
    }
  }

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
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      TerminalDropText.text(for: urls) != nil
    else { return [] }
    return .copy
  }

  private var canReceiveFileDrop: Bool {
    guard acceptsFileDrops, surface != nil, window != nil, !isHiddenOrHasHiddenAncestor else {
      return false
    }
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
