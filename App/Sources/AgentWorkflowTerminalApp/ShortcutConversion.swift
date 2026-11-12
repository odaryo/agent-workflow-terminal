import AppKit
import Carbon
import SwiftUI
import TerminalCore

enum ShortcutConversion {
  private static let characterCodes: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
    "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
  ]

  static func keyboardShortcut(_ combination: KeyCombination) -> KeyboardShortcut? {
    let key: KeyEquivalent
    switch combination.key {
    case .character(let value):
      guard value.count == 1, let character = value.first else { return nil }
      key = KeyEquivalent(character)
    case .upArrow: key = .upArrow
    case .downArrow: key = .downArrow
    case .leftArrow: key = .leftArrow
    case .rightArrow: key = .rightArrow
    case .space: key = .space
    }
    return KeyboardShortcut(key, modifiers: eventModifiers(combination.modifiers))
  }

  private static func eventModifiers(_ input: Set<ShortcutModifier>) -> SwiftUI.EventModifiers {
    var result: SwiftUI.EventModifiers = []
    if input.contains(.command) { result.insert(.command) }
    if input.contains(.shift) { result.insert(.shift) }
    if input.contains(.option) { result.insert(.option) }
    if input.contains(.control) { result.insert(.control) }
    return result
  }

  static func carbon(_ combination: KeyCombination) -> (keyCode: UInt32, modifiers: UInt32)? {
    let code: UInt32
    switch combination.key {
    case .character(let character):
      guard let mapped = characterCodes[character] else { return nil }
      code = mapped
    case .upArrow: code = 126
    case .downArrow: code = 125
    case .leftArrow: code = 123
    case .rightArrow: code = 124
    case .space: code = 49
    }
    return (code, carbonModifiers(combination.modifiers))
  }

  private static func carbonModifiers(_ input: Set<ShortcutModifier>) -> UInt32 {
    var result: UInt32 = 0
    if input.contains(.command) { result |= UInt32(cmdKey) }
    if input.contains(.shift) { result |= UInt32(shiftKey) }
    if input.contains(.option) { result |= UInt32(optionKey) }
    if input.contains(.control) { result |= UInt32(controlKey) }
    return result
  }

  static func recorded(
    keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
  ) -> KeyCombination? {
    let key: ShortcutKey
    switch keyCode {
    case 123: key = .leftArrow
    case 124: key = .rightArrow
    case 125: key = .downArrow
    case 126: key = .upArrow
    case 49: key = .space
    default:
      guard let characters, characters.unicodeScalars.count == 1,
        let scalar = characters.unicodeScalars.first, (0x21...0x7E).contains(scalar.value)
      else { return nil }
      key = .character(characters)
    }
    return KeyCombination(key: key, modifiers: recordedModifiers(modifiers))
  }

  private static func recordedModifiers(_ modifiers: NSEvent.ModifierFlags) -> Set<ShortcutModifier>
  {
    var mapped: Set<ShortcutModifier> = []
    if modifiers.contains(.command) { mapped.insert(.command) }
    if modifiers.contains(.shift) { mapped.insert(.shift) }
    if modifiers.contains(.option) { mapped.insert(.option) }
    if modifiers.contains(.control) { mapped.insert(.control) }
    return mapped
  }

  static func display(_ combination: KeyCombination) -> String {
    let symbols: [(ShortcutModifier, String)] = [
      (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]
    let prefix = symbols.filter { combination.modifiers.contains($0.0) }.map(\.1).joined()
    let key: String
    switch combination.key {
    case .character(let character): key = character.uppercased()
    case .upArrow: key = "↑"
    case .downArrow: key = "↓"
    case .leftArrow: key = "←"
    case .rightArrow: key = "→"
    case .space: key = "Space"
    }
    return prefix + key
  }
}

extension ShortcutAction {
  var settingsName: String {
    switch self {
    case .previousProject: "前のプロジェクト"
    case .nextProject: "次のプロジェクト"
    case .collapseProject: "プロジェクトを閉じる"
    case .expandProject: "プロジェクトを開く"
    case .previousSession: "前のセッション"
    case .nextSession: "次のセッション"
    case .toggleOverview: "Overview の表示切り替え"
    case .toggleCodeViewer: "Code Viewer の表示切り替え"
    case .toggleDiffViewer: "Diff Viewer の表示切り替え"
    case .bringAppToFront: "アプリを前面に出す"
    }
  }
}
