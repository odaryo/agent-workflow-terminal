import AppKit
import GhosttyKit

extension GhosttySurfaceView {
  override public func keyDown(with event: NSEvent) {
    guard let surface else {
      super.keyDown(with: event)
      return
    }

    let translationEvent = translationEvent(for: event, surface: surface)

    let hadMarkedText = markedTextStorage.length > 0
    textAccumulator = []
    interpretKeyEvents([translationEvent])
    let insertedText = (textAccumulator ?? []).filter(Self.isPrintableText)
    textAccumulator = nil
    synchronizePreedit(clearIfNeeded: hadMarkedText)

    if !insertedText.isEmpty {
      for text in insertedText {
        var key = makeKeyEvent(
          event, action: GHOSTTY_ACTION_PRESS, consumedFlags: translationEvent.modifierFlags
        )
        text.withCString { pointer in
          key.text = pointer
          _ = ghostty_surface_key(surface, key)
        }
      }
      return
    }

    var key = makeKeyEvent(
      event, action: GHOSTTY_ACTION_PRESS, consumedFlags: translationEvent.modifierFlags
    )
    key.composing = markedTextStorage.length > 0 || hadMarkedText
    if key.composing {
      key.text = nil
      _ = ghostty_surface_key(surface, key)
      return
    }

    guard let text = ghosttyText(for: translationEvent) else {
      key.text = nil
      _ = ghostty_surface_key(surface, key)
      return
    }
    text.withCString { pointer in
      key.text = pointer
      _ = ghostty_surface_key(surface, key)
    }
  }

  private func translationEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
    // Why not 元の修飾で文字を生成: option-as-alt でも特殊文字やデッドキーになってしまう。
    let translated = ghostty_surface_key_translation_mods(
      surface, GhosttyKeyModifiers.ghosttyMods(event.modifierFlags)
    )
    let flags = GhosttyKeyModifiers.translationFlags(
      original: event.modifierFlags, translated: translated
    )
    // Why not 常にイベントを再生成: 韓国語入力は元イベントの同一性に依存する (上流 Ghostty の知見)。
    guard flags != event.modifierFlags else { return event }
    return NSEvent.keyEvent(
      with: event.type,
      location: event.locationInWindow,
      modifierFlags: flags,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      characters: event.characters(byApplyingModifiers: flags) ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat,
      keyCode: event.keyCode
    ) ?? event
  }

  override public func keyUp(with event: NSEvent) {
    guard let surface else {
      super.keyUp(with: event)
      return
    }
    var key = makeKeyEvent(
      event, action: GHOSTTY_ACTION_RELEASE, consumedFlags: event.modifierFlags
    )
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
    key.mods = GhosttyKeyModifiers.ghosttyMods(event.modifierFlags)
    key.consumed_mods = GHOSTTY_MODS_NONE
    key.unshifted_codepoint = 0
    key.composing = false
    key.text = nil

    key.action = GhosttyKeyModifiers.modifierKeyAction(
      keyCode: event.keyCode, flags: event.modifierFlags
    )
    _ = ghostty_surface_key(surface, key)
  }

  private func makeKeyEvent(
    _ event: NSEvent,
    action: ghostty_input_action_e,
    consumedFlags: NSEvent.ModifierFlags
  ) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action =
      event.isARepeat && action == GHOSTTY_ACTION_PRESS
      ? GHOSTTY_ACTION_REPEAT : action
    key.keycode = UInt32(event.keyCode)
    key.mods = GhosttyKeyModifiers.ghosttyMods(event.modifierFlags)
    key.consumed_mods = GhosttyKeyModifiers.ghosttyMods(
      consumedFlags.subtracting([.control, .command])
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
