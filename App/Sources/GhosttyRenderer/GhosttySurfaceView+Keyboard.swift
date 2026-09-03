import AppKit
import GhosttyKit

extension GhosttySurfaceView {
  override public func keyDown(with event: NSEvent) {
    guard let surface else {
      super.keyDown(with: event)
      return
    }

    let hadMarkedText = markedTextStorage.length > 0
    textAccumulator = []
    interpretKeyEvents([event])
    let insertedText = (textAccumulator ?? []).filter(Self.isPrintableText)
    textAccumulator = nil
    synchronizePreedit(clearIfNeeded: hadMarkedText)

    if !insertedText.isEmpty {
      for text in insertedText {
        var key = makeKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        text.withCString { pointer in
          key.text = pointer
          _ = ghostty_surface_key(surface, key)
        }
      }
      return
    }

    var key = makeKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
    key.composing = markedTextStorage.length > 0 || hadMarkedText
    if key.composing {
      key.text = nil
      _ = ghostty_surface_key(surface, key)
      return
    }

    guard let text = ghosttyText(for: event) else {
      key.text = nil
      _ = ghostty_surface_key(surface, key)
      return
    }
    text.withCString { pointer in
      key.text = pointer
      _ = ghostty_surface_key(surface, key)
    }
  }

  override public func keyUp(with event: NSEvent) {
    guard let surface else {
      super.keyUp(with: event)
      return
    }
    var key = makeKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    key.text = nil
    _ = ghostty_surface_key(surface, key)
  }

  override public func flagsChanged(with event: NSEvent) {
    guard let surface else {
      super.flagsChanged(with: event)
      return
    }
    var key = ghostty_input_key_s()
    key.keycode = UInt32(event.keyCode)
    key.mods = Self.modifiers(from: event.modifierFlags)
    key.consumed_mods = GHOSTTY_MODS_NONE
    key.unshifted_codepoint = 0
    key.composing = false
    key.text = nil

    let pressed: Bool
    switch Int(event.keyCode) {
    case 56, 60: pressed = event.modifierFlags.contains(.shift)
    case 59, 62: pressed = event.modifierFlags.contains(.control)
    case 58, 61: pressed = event.modifierFlags.contains(.option)
    case 54, 55: pressed = event.modifierFlags.contains(.command)
    case 57: pressed = event.modifierFlags.contains(.capsLock)
    case 63: pressed = event.modifierFlags.contains(.function)
    default: pressed = false
    }
    key.action = pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, key)
  }

  private func makeKeyEvent(
    _ event: NSEvent,
    action: ghostty_input_action_e
  ) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action =
      event.isARepeat && action == GHOSTTY_ACTION_PRESS
      ? GHOSTTY_ACTION_REPEAT : action
    key.keycode = UInt32(event.keyCode)
    key.mods = Self.modifiers(from: event.modifierFlags)
    key.consumed_mods = Self.modifiers(
      from: event.modifierFlags.subtracting([.control, .command])
    )
    key.unshifted_codepoint =
      event.characters(byApplyingModifiers: [])?
      .unicodeScalars.first?.value ?? 0
    key.composing = false
    key.text = nil
    return key
  }

  private func ghosttyText(for event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }
    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      if scalar.value < 0x20 || scalar.value == 0x7F {
        return event.characters(
          byApplyingModifiers: event.modifierFlags.subtracting(.control)
        )
      }
      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
    }
    return characters
  }

  private static func isPrintableText(_ text: String) -> Bool {
    guard text.count == 1, let scalar = text.unicodeScalars.first else { return true }
    return scalar.value >= 0x20 && scalar.value != 0x7F
      && !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF)
  }

  static func modifiers(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var value = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(value)
  }

  func synchronizePreedit(clearIfNeeded: Bool) {
    guard let surface else { return }
    guard markedTextStorage.length > 0 else {
      if clearIfNeeded { ghostty_surface_preedit(surface, nil, 0) }
      return
    }

    let bytes = Array(markedTextStorage.string.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
        ghostty_surface_preedit(surface, pointer, UInt(buffer.count))
      }
    }
  }

  func sendText(_ text: String) {
    guard let surface else { return }
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
        ghostty_surface_text(surface, pointer, UInt(buffer.count))
      }
    }
  }
}
