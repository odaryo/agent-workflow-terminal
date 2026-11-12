import AppKit
import GhosttyKit
import Testing

@testable import GhosttyRenderer

struct GhosttyKeyModifiersTests {
  struct DeviceCase: Sendable, CustomTestStringConvertible {
    let generic: NSEvent.ModifierFlags
    let device: UInt
    let expected: UInt32

    init(_ generic: NSEvent.ModifierFlags, _ device: UInt, _ expected: UInt32) {
      self.generic = generic
      self.device = device
      self.expected = expected
    }

    var testDescription: String {
      "generic=\(generic.rawValue) device=\(device) expected=\(expected)"
    }
  }

  struct KeyActionCase: Sendable, CustomTestStringConvertible {
    let keyCode: UInt16
    let generic: NSEvent.ModifierFlags
    let device: UInt
    let pressed: Bool

    init(_ keyCode: UInt16, _ generic: NSEvent.ModifierFlags, _ device: UInt, _ pressed: Bool) {
      self.keyCode = keyCode
      self.generic = generic
      self.device = device
      self.pressed = pressed
    }

    var testDescription: String {
      "keyCode=\(keyCode) generic=\(generic.rawValue) device=\(device) pressed=\(pressed)"
    }
  }

  struct TranslationCase: Sendable, CustomTestStringConvertible {
    let original: NSEvent.ModifierFlags
    let translated: UInt32
    let expected: NSEvent.ModifierFlags

    init(_ original: NSEvent.ModifierFlags, _ translated: UInt32, _ expected: NSEvent.ModifierFlags)
    {
      self.original = original
      self.translated = translated
      self.expected = expected
    }

    var testDescription: String {
      "original=\(original.rawValue) translated=\(translated) expected=\(expected.rawValue)"
    }
  }

  static let genericCases: [(NSEvent.ModifierFlags, UInt32)] = [
    (.shift, GHOSTTY_MODS_SHIFT.rawValue),
    (.control, GHOSTTY_MODS_CTRL.rawValue),
    (.option, GHOSTTY_MODS_ALT.rawValue),
    (.command, GHOSTTY_MODS_SUPER.rawValue),
    (.capsLock, GHOSTTY_MODS_CAPS.rawValue),
    ([], GHOSTTY_MODS_NONE.rawValue),
  ]

  @Test(arguments: genericCases)
  func mapsGenericModifiers(flags: NSEvent.ModifierFlags, expected: UInt32) {
    #expect(GhosttyKeyModifiers.ghosttyMods(flags).rawValue == expected)
  }

  static let deviceCases: [DeviceCase] = [
    DeviceCase(
      .shift, UInt(NX_DEVICERSHIFTKEYMASK),
      GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue
    ),
    DeviceCase(
      .control, UInt(NX_DEVICERCTLKEYMASK),
      GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_CTRL_RIGHT.rawValue
    ),
    DeviceCase(
      .option, UInt(NX_DEVICERALTKEYMASK),
      GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_ALT_RIGHT.rawValue
    ),
    DeviceCase(
      .command, UInt(NX_DEVICERCMDKEYMASK),
      GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SUPER_RIGHT.rawValue
    ),
    DeviceCase(.shift, UInt(NX_DEVICELSHIFTKEYMASK), GHOSTTY_MODS_SHIFT.rawValue),
    DeviceCase(
      .shift, UInt(NX_DEVICELSHIFTKEYMASK) | UInt(NX_DEVICERSHIFTKEYMASK),
      GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue
    ),
  ]

  @Test(arguments: deviceCases)
  func mapsDeviceModifiers(_ testCase: DeviceCase) {
    let flags = NSEvent.ModifierFlags(rawValue: testCase.generic.rawValue | testCase.device)
    #expect(GhosttyKeyModifiers.ghosttyMods(flags).rawValue == testCase.expected)
  }

  static let keyActionCases: [KeyActionCase] = [
    KeyActionCase(60, .shift, UInt(NX_DEVICERSHIFTKEYMASK), true),
    KeyActionCase(
      60, .shift, UInt(NX_DEVICELSHIFTKEYMASK) | UInt(NX_DEVICERSHIFTKEYMASK), true
    ),
    KeyActionCase(60, .shift, UInt(NX_DEVICELSHIFTKEYMASK), false),
    KeyActionCase(56, .shift, UInt(NX_DEVICERSHIFTKEYMASK), false),
    KeyActionCase(58, .option, UInt(NX_DEVICERALTKEYMASK), false),
    KeyActionCase(59, .control, UInt(NX_DEVICERCTLKEYMASK), false),
    KeyActionCase(54, .command, UInt(NX_DEVICELCMDKEYMASK), false),
    KeyActionCase(61, .option, UInt(NX_DEVICERALTKEYMASK), true),
    KeyActionCase(62, .control, UInt(NX_DEVICERCTLKEYMASK), true),
    KeyActionCase(54, .command, UInt(NX_DEVICERCMDKEYMASK), true),
    KeyActionCase(55, .command, UInt(NX_DEVICELCMDKEYMASK), true),
    KeyActionCase(60, .shift, 0, true),
    KeyActionCase(56, .shift, 0, true),
    KeyActionCase(60, [], 0, false),
    KeyActionCase(60, [], UInt(NX_DEVICERSHIFTKEYMASK), false),
    KeyActionCase(57, .capsLock, 0, true),
    KeyActionCase(57, [], 0, false),
    KeyActionCase(63, .function, 0, true),
    KeyActionCase(63, [], 0, false),
    KeyActionCase(0, [.shift, .control, .option, .command, .capsLock, .function], 0, false),
  ]

  @Test(arguments: keyActionCases)
  func identifiesModifierKeyAction(_ testCase: KeyActionCase) {
    let flags = NSEvent.ModifierFlags(rawValue: testCase.generic.rawValue | testCase.device)
    let expected = testCase.pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    #expect(
      GhosttyKeyModifiers.modifierKeyAction(keyCode: testCase.keyCode, flags: flags).rawValue
        == expected.rawValue
    )
  }

  @Test func preservesAllOriginalBitsWhenTranslationMatches() {
    let generic: NSEvent.ModifierFlags = [
      .shift, .control, .option, .command, .capsLock, .function, .numericPad,
    ]
    let original = NSEvent.ModifierFlags(
      rawValue: generic.rawValue | UInt(NX_DEVICERALTKEYMASK)
    )
    let translated = ghostty_input_mods_e(
      GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_CTRL.rawValue
        | GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_CAPS.rawValue
    )
    #expect(
      GhosttyKeyModifiers.translationFlags(original: original, translated: translated).rawValue
        == original.rawValue
    )
  }

  @Test func removingOptionPreservesDeviceAndCapsLockBits() {
    let original = NSEvent.ModifierFlags(
      rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK)
        | NSEvent.ModifierFlags.capsLock.rawValue
    )
    let translated = GhosttyKeyModifiers.translationFlags(
      original: original, translated: GHOSTTY_MODS_CAPS
    )
    #expect(!translated.contains(.option))
    #expect(translated.contains(.capsLock))
    #expect(translated.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0)
    #expect(translated.rawValue == original.rawValue & ~NSEvent.ModifierFlags.option.rawValue)
  }

  static let translationCases: [TranslationCase] = [
    TranslationCase(.option, GHOSTTY_MODS_NONE.rawValue, []),
    TranslationCase([.option, .shift], GHOSTTY_MODS_SHIFT.rawValue, .shift),
    TranslationCase([], GHOSTTY_MODS_SUPER.rawValue, .command),
    TranslationCase([], GHOSTTY_MODS_CTRL.rawValue, .control),
    TranslationCase([], GHOSTTY_MODS_ALT.rawValue, .option),
    TranslationCase([], GHOSTTY_MODS_SHIFT.rawValue, .shift),
    TranslationCase([.shift, .control, .option, .command], GHOSTTY_MODS_NONE.rawValue, []),
  ]

  @Test(arguments: translationCases)
  func appliesTranslatedGenericFlags(_ testCase: TranslationCase) {
    let result = GhosttyKeyModifiers.translationFlags(
      original: testCase.original, translated: ghostty_input_mods_e(testCase.translated)
    )
    #expect(result.rawValue == testCase.expected.rawValue)
  }
}
