import AppKit
import GhosttyKit

enum GhosttyKeyModifiers {
  static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var value = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
    if flags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0 {
      value |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue
    }
    if flags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0 {
      value |= GHOSTTY_MODS_CTRL_RIGHT.rawValue
    }
    if flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0 {
      value |= GHOSTTY_MODS_ALT_RIGHT.rawValue
    }
    if flags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0 {
      value |= GHOSTTY_MODS_SUPER_RIGHT.rawValue
    }
    return ghostty_input_mods_e(value)
  }

  static func modifierKeyAction(
    keyCode: UInt16, flags: NSEvent.ModifierFlags
  ) -> ghostty_input_action_e {
    let modifier: SidedModifier
    switch keyCode {
    case 56, 60:
      modifier = SidedModifier(
        generic: .shift, left: UInt(NX_DEVICELSHIFTKEYMASK),
        right: UInt(NX_DEVICERSHIFTKEYMASK), isRight: keyCode == 60)
    case 59, 62:
      modifier = SidedModifier(
        generic: .control, left: UInt(NX_DEVICELCTLKEYMASK),
        right: UInt(NX_DEVICERCTLKEYMASK), isRight: keyCode == 62)
    case 58, 61:
      modifier = SidedModifier(
        generic: .option, left: UInt(NX_DEVICELALTKEYMASK),
        right: UInt(NX_DEVICERALTKEYMASK), isRight: keyCode == 61)
    case 55, 54:
      modifier = SidedModifier(
        generic: .command, left: UInt(NX_DEVICELCMDKEYMASK),
        right: UInt(NX_DEVICERCMDKEYMASK), isRight: keyCode == 54)
    case 57:
      return flags.contains(.capsLock) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    case 63:
      return flags.contains(.function) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    default:
      return GHOSTTY_ACTION_RELEASE
    }
    guard flags.contains(modifier.generic) else { return GHOSTTY_ACTION_RELEASE }
    let deviceBits = flags.rawValue & (modifier.left | modifier.right)
    let side = modifier.isRight ? modifier.right : modifier.left
    return deviceBits == 0 || deviceBits & side != 0
      ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
  }

  private struct SidedModifier {
    let generic: NSEvent.ModifierFlags
    let left: UInt
    let right: UInt
    let isRight: Bool
  }

  static func translationFlags(
    original: NSEvent.ModifierFlags, translated: ghostty_input_mods_e
  ) -> NSEvent.ModifierFlags {
    let modifiers: [(NSEvent.ModifierFlags, ghostty_input_mods_e)] = [
      (.shift, GHOSTTY_MODS_SHIFT),
      (.control, GHOSTTY_MODS_CTRL),
      (.option, GHOSTTY_MODS_ALT),
      (.command, GHOSTTY_MODS_SUPER),
    ]
    var flags = original
    for (flag, mod) in modifiers {
      if translated.rawValue & mod.rawValue != 0 {
        flags.insert(flag)
      } else {
        flags.remove(flag)
      }
    }
    return flags
  }
}
