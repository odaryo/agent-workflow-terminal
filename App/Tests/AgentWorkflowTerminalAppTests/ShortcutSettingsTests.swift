import AppKit
import Carbon
import Foundation
import SwiftUI
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

struct ShortcutSettingsTests {
  @Test("⌘⇧, は Shift なしの文字で記録し、予約の ⌘, と区別する")
  func shiftedComma() throws {
    let combination = try #require(
      ShortcutConversion.recorded(keyCode: 43, characters: ",", modifiers: [.command, .shift]))
    #expect(combination == KeyCombination(key: .character(","), modifiers: [.command, .shift]))
    let shortcut = try #require(ShortcutConversion.keyboardShortcut(combination))
    #expect(shortcut.key == KeyEquivalent(","))
    #expect(shortcut.modifiers == [.command, .shift])
    let carbon = try #require(ShortcutConversion.carbon(combination))
    #expect(carbon.keyCode == 43)
    #expect(carbon.modifiers == UInt32(cmdKey | shiftKey))
    #expect(ShortcutConversion.display(combination) == "⇧⌘,")
    #expect(
      ShortcutConversion.carbon(KeyCombination(key: .character("<"), modifiers: [.command])) == nil)
  }

  @Test(
    "矢印と Space を記録・変換・表示する",
    arguments: [
      (UInt16(123), ShortcutKey.leftArrow), (124, .rightArrow),
      (125, .downArrow), (126, .upArrow), (49, .space),
    ])
  func specialKeys(input: (UInt16, ShortcutKey)) throws {
    let combination = KeyCombination(
      key: input.1, modifiers: [.control, .option, .shift, .command])
    #expect(
      ShortcutConversion.recorded(
        keyCode: input.0, characters: nil,
        modifiers: [.control, .option, .shift, .command]) == combination)
    let carbon = try #require(ShortcutConversion.carbon(combination))
    #expect(carbon.keyCode == UInt32(input.0))
    #expect(ShortcutConversion.keyboardShortcut(combination) != nil)
    let labels: [ShortcutKey: String] = [
      .leftArrow: "←", .rightArrow: "→", .downArrow: "↓", .upArrow: "↑", .space: "Space",
    ]
    let label = try #require(labels[input.1])
    #expect(ShortcutConversion.display(combination) == "⌃⌥⇧⌘" + label)
  }

  @Test(
    "US 配列で Shift なしの文字だけを Carbon へ変換する",
    arguments: Array("abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`"))
  func unshiftedCharacters(character: Character) throws {
    let combination = KeyCombination(key: .character(String(character)), modifiers: [.command])
    let mapped = try #require(ShortcutConversion.carbon(combination))
    #expect(mapped.modifiers == UInt32(cmdKey))
    #expect(ShortcutConversion.keyboardShortcut(combination)?.key == KeyEquivalent(character))
    #expect(ShortcutConversion.display(combination) == "⌘" + String(character).uppercased())
  }

  @Test("ASCII 表示文字以外の記録は拒否する", arguments: ["", "ab", "あ", "\t", "\r"])
  func unsupportedRecording(characters: String) {
    #expect(
      ShortcutConversion.recorded(keyCode: 36, characters: characters, modifiers: .command) == nil)
  }

  @MainActor
  @Test("読めない保存項目の件数を保持する")
  func droppedEntries() throws {
    let name = "ShortcutSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(Data(#"{"nextProject":null}"#.utf8), forKey: "shortcutBindings")
    let store = ShortcutSettingsStore(defaults: defaults)
    #expect(store.droppedCount == 1)
    #expect(store.bindings == ShortcutBindings())
  }

  @MainActor
  @Test("Carbon 非対応と登録失敗では割り当てと保存値を保つ")
  func failedGlobalRegistration() throws {
    let name = "ShortcutSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ShortcutSettingsStore(defaults: defaults)
    try store.assign(
      KeyCombination(key: .character("<"), modifiers: [.command]), to: .bringAppToFront)
    #expect(store.bindings.isDefault(.bringAppToFront))
    #expect(store.errors[.bringAppToFront] == "このキーはシステム全体のショートカットに使えません")
    store.registerGlobalHotKey = { _ in "登録できませんでした (status -9878)" }
    try store.assign(
      KeyCombination(key: .character("j"), modifiers: [.command]), to: .bringAppToFront)
    #expect(store.bindings.isDefault(.bringAppToFront))
    #expect(defaults.data(forKey: "shortcutBindings") == nil)
    #expect(store.errors[.bringAppToFront] == "登録できませんでした (status -9878)")
  }

  @MainActor
  @Test("変更と既定への復帰を保存し、競合時には保存値も変更しない")
  func persistence() throws {
    let name = "ShortcutSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ShortcutSettingsStore(defaults: defaults)
    let custom = KeyCombination(key: .character("j"), modifiers: [.command, .shift])
    try store.assign(custom, to: .nextProject)
    let restored = ShortcutSettingsStore(defaults: defaults)
    #expect(restored.bindings.combination(for: .nextProject) == custom)
    let saved = defaults.data(forKey: "shortcutBindings")
    #expect(throws: ShortcutAssignmentError.conflict(.nextProject)) {
      try store.assign(custom, to: .previousProject)
    }
    #expect(store.bindings.isDefault(.previousProject))
    #expect(defaults.data(forKey: "shortcutBindings") == saved)
    try store.resetToDefault(.nextProject)
    #expect(ShortcutSettingsStore(defaults: defaults).bindings.isDefault(.nextProject))
    try store.assign(custom, to: .nextProject)
    store.resetAll()
    #expect(ShortcutSettingsStore(defaults: defaults).bindings == ShortcutBindings())
  }
}
