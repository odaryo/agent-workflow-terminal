import AppKit
import GhosttyKit

extension GhosttySurfaceView {
  override public func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [
        .mouseEnteredAndExited, .mouseMoved, .inVisibleRect,
        .activeInKeyWindow, .cursorUpdate,
      ],
      owner: self
    )
    addTrackingArea(area)
    trackingAreaReference = area
  }

  override public func mouseDown(with event: NSEvent) {
    reportMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
  }

  override public func mouseUp(with event: NSEvent) {
    reportMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
  }

  override public func rightMouseDown(with event: NSEvent) {
    reportMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
  }

  override public func rightMouseUp(with event: NSEvent) {
    reportMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
  }

  override public func mouseMoved(with event: NSEvent) { reportMousePosition(event) }
  override public func mouseDragged(with event: NSEvent) { reportMousePosition(event) }
  override public func rightMouseDragged(with event: NSEvent) { reportMousePosition(event) }

  private func reportMouseButton(
    _ event: NSEvent,
    state: ghostty_input_mouse_state_e,
    button: ghostty_input_mouse_button_e
  ) {
    guard let surface else { return }
    _ = ghostty_surface_mouse_button(
      surface, state, button, Self.modifiers(from: event.modifierFlags)
    )
  }

  private func reportMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface, point.x, bounds.height - point.y,
      Self.modifiers(from: event.modifierFlags)
    )
  }

  override public func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    var modifiers: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
    let momentum: Int32
    switch event.momentumPhase {
    case .began: momentum = 1
    case .stationary: momentum = 2
    case .changed: momentum = 3
    case .ended: momentum = 4
    case .cancelled: momentum = 5
    case .mayBegin: momentum = 6
    default: momentum = 0
    }
    modifiers |= momentum << 1
    ghostty_surface_mouse_scroll(
      surface, event.scrollingDeltaX, event.scrollingDeltaY,
      ghostty_input_scroll_mods_t(modifiers)
    )
  }
}

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
  public func hasMarkedText() -> Bool { markedTextStorage.length > 0 }

  public func markedRange() -> NSRange {
    markedTextStorage.length > 0
      ? NSRange(location: 0, length: markedTextStorage.length)
      : NSRange(location: NSNotFound, length: 0)
  }

  public func selectedRange() -> NSRange {
    NSRange(location: markedTextStorage.length, length: 0)
  }

  public func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    switch string {
    case let value as NSAttributedString:
      markedTextStorage.setAttributedString(value)
    case let value as String:
      markedTextStorage.mutableString.setString(value)
    default:
      markedTextStorage.mutableString.setString("")
    }
    if textAccumulator == nil { synchronizePreedit(clearIfNeeded: true) }
  }

  public func unmarkText() {
    guard markedTextStorage.length > 0 else { return }
    markedTextStorage.mutableString.setString("")
    if textAccumulator == nil { synchronizePreedit(clearIfNeeded: true) }
  }

  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  public func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? { nil }

  public func characterIndex(for point: NSPoint) -> Int { 0 }

  public func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    guard let viewRectangle = imeRectangle else {
      return window?.convertToScreen(convert(bounds, to: nil)) ?? bounds
    }
    let windowRectangle = convert(viewRectangle, to: nil)
    return window?.convertToScreen(windowRectangle) ?? windowRectangle
  }

  public func insertText(_ string: Any, replacementRange: NSRange) {
    let text: String
    switch string {
    case let value as NSAttributedString: text = value.string
    case let value as String: text = value
    default: return
    }

    unmarkText()
    if textAccumulator != nil {
      textAccumulator?.append(text)
    } else {
      sendText(text)
    }
  }

  override public func doCommand(by selector: Selector) {}
}
